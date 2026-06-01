# Follow-up #342 — Tracking manager's atomic spinlock + alloc-tracking MUST
# lower + run on single-threaded wasm32-wasi.
#
# `Memory.Tracking` guards every allocation with canaries and tracks live
# allocations under a spinlock built directly on atomics
# (src/memory/tracking/manager.zig):
#   * `spinLock`   -> `@cmpxchgStrong(SpinLockState, state, .unlocked, .locked,
#                      .acquire, .monotonic)`
#   * `spinUnlock` -> `@atomicStore(SpinLockState, state, .unlocked, .release)`
# On wasm32 the `atomics` target feature is OPTIONAL — this fixture forces the
# tracked alloc/free path (and therefore the spinlock's cmpxchg + atomic store)
# to actually run, so we can confirm LLVM lowers `@cmpxchgStrong` / `@atomicStore`
# on single-threaded wasm rather than erroring.
#
# It allocates + frees many tracked objects (a `[{String, i64}]` list, sorted
# then walked) so the tracking table is locked/unlocked on every alloc and every
# free. Tracking also reports leaks and double-frees: a correct run prints the
# rows with NO `leak summary` / `memory leak:` / double-free diagnostic and
# exits 0. If `@cmpxchgStrong` had been miscompiled the spinlock would deadlock
# (wasmtime hang) or corrupt the tracking table (spurious leak/double-free
# report); if `@atomicStore` were a no-op the lock would never release (hang).
#
# Expected stdout (descending by count), nothing on stderr, exit 0:
#   AT 150
#   AC 100
#   GT 50

fn main(_args :: [String]) -> u8 {
  rows = [{"AC", 100 :: i64}, {"GT", 50 :: i64}, {"AT", 150 :: i64}]
  sorted = Enum.sort(rows, fn(left :: {String, i64}, right :: {String, i64}) -> Bool {
    {_left_kmer, left_count} = left
    {_right_kmer, right_count} = right
    left_count > right_count
  })
  _ = Enum.each(sorted, fn(row :: {String, i64}) -> String {
    {kmer, count} = row
    IO.puts(kmer <> " " <> Integer.to_string(count))
  })
  0
}
