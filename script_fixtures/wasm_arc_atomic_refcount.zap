# Follow-up #342 — ARC atomic-refcount path MUST lower + run on single-threaded
# wasm32-wasi.
#
# The Phase-A "IO.puts runs on wasi" proof used Arena/NoOp/Leak (atomics-free)
# and a trivial fixture, so it never exercised ARC's atomic refcount path. ARC's
# `retain` is `@atomicRmw(u32, ptr, .Add, 1, .monotonic)` and `release` is
# `@atomicRmw(u32, ptr, .Sub, 1, .acq_rel)` (src/memory/arc/manager.zig ~949).
# On wasm32 the `atomics` target feature is OPTIONAL — this fixture forces those
# ops to actually run so we can confirm LLVM lowers ordered atomics on
# single-threaded wasm (to plain loads/stores) rather than erroring.
#
# This is the canonical ARC retain/release-heavy shape (modelled on
# src/test_reductions/list_sort_each_arc_double_free.zap): a `[{String, i64}]`
# list that is sorted then walked. It drives every atomic refcount edge:
#
#   * each `{String, i64}` row holds an ARC-managed `String` (heap, refcounted).
#   * the list spine itself is ARC-managed: `List.next` / `List.getHead` /
#     `List.getTail` deep-RETAIN the head's ARC children (atomic increment) so
#     the cell's owner-side deep-release stays balanced.
#   * `Enum.sort` reorders rows through a comparator closure — each row tuple
#     and its String are retained/released as they move between cells.
#   * `Enum.each` walks every row, destructures the tuple (binding the String),
#     prints it, and drops it (release -> on zero-transition, the `.acq_rel`
#     decrement that frees the String backing).
#
# If a retain were miscompiled to a no-op on wasm (lost increment), a String
# would be freed while still referenced and the print would read freed memory
# (garbage / trap under wasmtime); a double-decrement would underflow and
# double-free (wasmtime trap). A correct run prints the rows in descending count
# order and exits 0.
#
# Expected stdout (descending by count):
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
