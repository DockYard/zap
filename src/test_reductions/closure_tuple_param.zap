# Reduced reproducer — closure with a tuple parameter passed
# through `Enum.reduce`. Currently fails after HIR with:
#
#   Error: compilation failed: EmitFailed
#
# The research brief diagnoses this as a body-scoping bug in the
# ZIR backend: type-support instructions for the closure's
# tuple-typed parameter (or tuple-typed return) leak outside the
# inline body Sema expects them in. Documented in
# `docs/clbg-three-bench-blockers-research-brief.md` §8.4.

pub struct Probe {
  pub fn run() -> i64 {
    pairs = [{"a", 1 :: i64}, {"b", 2 :: i64}]
    Enum.reduce(pairs, 0 :: i64, fn(p :: {String, i64}, acc :: i64) -> i64 {
      {_, n} = p
      acc + n
    })
  }
}
