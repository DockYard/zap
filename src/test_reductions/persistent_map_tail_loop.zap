# Microbench reproducer — Phase 1 of the k-nucleotide RSS roadmap
# (`docs/k-nucleotide-rss-gap-implementation-plan.md`).
#
# Tail-recursive `Map.put` loop: thread a `Map<i64, i64>` through
# 100,000 puts, then read one entry to keep the result live and
# print "done". With ARC instrumentation enabled
# (`ZAP_ARC_STATS=1`), the per-(K,V) Map pool's high-water-mark is
# the load-bearing signal: today it grows linearly with the loop
# bound because the IR never emits scope-exit `release` for `m` /
# `next_map`, so every path-copy spine accumulates instead of
# being reclaimed. Phase 6 of the roadmap closes this leak by
# wiring `.map` into `IrBuilder.isArcManagedType`; once Phases
# 4-5 enable consume-at-last-use and return-source elision, this
# microbench's pool HWM stays bounded.
#
# Output is `50000\ndone`. The test harness only asserts on the
# stdout match — RSS / counter assertions follow later phases as
# the hooks get populated.

pub struct Probe {
  pub fn loop(m :: %{i64 => i64}, i :: i64, n :: i64) -> %{i64 => i64} {
    if i >= n {
      m
    } else {
      next = Map.put(m, i, i)
      Probe.loop(next, i + (1 :: i64), n)
    }
  }

  pub fn main() -> String {
    seed = %{-1 :: i64 => 0 :: i64}
    cleared = Map.delete(seed, -1 :: i64)
    result = Probe.loop(cleared, 0 :: i64, 100000 :: i64)
    Kernel.inspect(Map.get(result, 50000 :: i64, -1 :: i64))
    "done"
  }
}
