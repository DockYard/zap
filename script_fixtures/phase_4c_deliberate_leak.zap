# Phase 4.c acceptance — a deliberate, attributable heap leak under
# `Memory.Tracking`.
#
# `%Outer{cause: Option.Some(%Inner{})}` auto-boxes the inner `%Inner{}`
# into a `runtime.ProtocolBox(Error)` (the `cause :: Option(Error)` field
# auto-injected into every `pub error`) and heap-promotes it through
# `ArcRuntime.allocAny`. Under `Memory.Tracking` (zero capabilities) that
# construction-site allocation flows through `core.allocate`; the outer
# value is then dropped without the deep-walk release that would reclaim
# the boxed inner, so the inner survives to `core.deinit`.
#
# (This is the SAME box-in-struct shape as `phase_1_2_5_e_cause_chain`,
# but here the outer is never walked/consumed — it is simply abandoned —
# so the leak is the deliberate, attributable survivor the Phase 4.c
# report describes. The cause-chain fixture, by contrast, is the one the
# #4 deep-release fix must drive to ZERO leaks.)
#
# Expected (text, under -Dmemory=Memory.Tracking):
#   * the program prints `built` then `main` returns 0
#   * a unified leak report follows on stderr:
#       warning: memory leak: Leaked 1 ... allocated at ...
#     carrying the Zap type, the symbolized allocation-site frame, the
#     size, the refcount, the gutter glyphs, and a deterministic summary.

@code Z9101
pub error Inner {}

@code Z9102
pub error Outer {}

fn main(_args :: [String]) -> u8 {
  leaked = %Outer{cause: Option.Some(%Inner{})}
  IO.puts("built")
  0
}
