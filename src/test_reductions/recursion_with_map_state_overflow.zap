# Reduced reproducer — a tail-recursive function that threads a
# `Map<i64, i64>` through every step blows the stack at ~150
# iterations with `:release_fast`. Pure-i64 tail recursion at
# 10,000 iterations works, so the compiler is *not* applying TCO
# when the accumulator is a heap-allocated `Map` (or possibly
# any heap-allocated value).
#
# This blocks the CLBG `k-nucleotide` benchmark port: count_kmers
# walks the THREE-block sequence with a sliding window and threads
# a `Map<i64, i64>` through every step. The smallest interesting
# inputs (~2.2M bases) require ~2.2M-deep tail-recursive calls
# with Map state, all of which currently consume real stack
# frames.
#
# Expected behavior: `loop/2` should compile to a tight inner
# iteration that reuses the current frame, or be lowerable to a
# `while` after structural rewriting. Compare with binarytrees'
# `sum_iter` (i64 accumulator) — that pattern *does* work even
# at very high iteration counts, which is why the failure mode
# here is map-specific.
#
# Reproduce with `loop(150 :: i64, ...)` — the program exits
# with signal 11 (SIGSEGV) on macOS aarch64 release-fast; pure-
# i64 `sum_iter`-style tail recursion at the same depth completes
# successfully. Reducing to 100 iterations passes here, so the
# stack-frame size of the Map-threaded variant is the gating
# factor.

pub struct RecursionWithMapStateOverflow {
  pub fn loop(remaining :: i64, m :: %{i64 => i64}) -> %{i64 => i64} {
    if remaining <= 0 {
      m
    } else {
      one = 1 :: i64
      previous = Map.get(m, remaining, 0 :: i64)
      next_count = previous + one
      next_map = Map.put(m, remaining, next_count)
      RecursionWithMapStateOverflow.loop(remaining - one, next_map)
    }
  }

  pub fn run(iterations :: i64) -> i64 {
    seed = %{-1 :: i64 => 0 :: i64}
    cleared = Map.delete(seed, -1 :: i64)
    final_map = RecursionWithMapStateOverflow.loop(iterations, cleared)
    Map.size(final_map)
  }
}
