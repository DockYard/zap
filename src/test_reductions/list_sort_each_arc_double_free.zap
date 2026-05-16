# Reduced reproducer — Phase H.3 ARC double-free in `Enum.sort` over
# `[{String, i64}]` followed by `Enum.each` (the canonical k-nucleotide
# print-rows shape). Demonstrates the runtime corruption that surfaces
# when `.list` joins the ARC-managed-type set in `isArcManagedTypeId`:
# `List.next`, `List.getHead`, and `List.getTail` returned
# `cell.head`/`cell.tail` without retaining, so the cell's deep-release
# on its eventual zero-transition raced with the caller's release of
# the values it had just received and produced double-frees of the
# String inside each row tuple.
#
# Phase H.3 fix lives in `src/runtime.zig`: `next`, `getHead`, and
# `getTail` now deep-retain the head's ARC children (via a
# `retainHeadChildren` mirror of `releaseHeadChildren`) and bump the
# tail spine's head-cell refcount, restoring symmetry with the
# cell's own owner-side deep-release. The fix is independent of the
# `.list` flag — it leaves unflipped runs unchanged because the IR
# never inserts the matching releases when `.list` is not ARC-managed.
#
# Once `.list` flips in `isArcManagedTypeId`, this program must
# produce:
#
#     AT 150
#     AC 100
#     GT 50

pub struct ListSortEachProbe {
  pub fn main(_args :: [String]) -> u8 {
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
}
