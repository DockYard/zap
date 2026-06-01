# Phase 2 acceptance — a GENUINELY undefined name must NOT be confused with a
# capability gate. `IO.get_charrr` is a typo: it is not defined on ANY target,
# so the diagnostic must be the ordinary "undefined" path, NEVER the
# `target_capability` diagnostic (the gate fires only for a name that DID
# resolve but is gated out). This guards the mutual exclusivity of the two arms.
#
# Expected: fails to compile on every target; the error must NOT contain
# "target_capability" / "capability" / "unavailable on".

fn main(args :: [String]) -> u8 {
  c = IO.get_charrr()
  IO.puts(c)
  0
}
