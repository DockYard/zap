# Reduced reproducer — `Enum.sort` with a comparator that takes
# tuple-typed arguments and destructures them. Combines the
# closure-tuple-param failure from `closure_tuple_param.zap` with
# the `<=` protocol dispatch on tuple-destructured String values
# from `tuple_protocol_dispatch.zap`. This is the exact shape
# k-nucleotide's frequency-table sort needs, so it stays as a
# regression once both upstream bugs are fixed.

pub struct Probe {
  pub fn run() -> [{String, i64}] {
    rows = [
      {"GC", 5 :: i64},
      {"AT", 9 :: i64},
      {"AA", 9 :: i64},
    ]
    Enum.sort(rows, fn(a :: {String, i64}, b :: {String, i64}) -> Bool {
      {a_kmer, a_count} = a
      {b_kmer, b_count} = b
      if a_count > b_count {
        true
      } else {
        if a_count < b_count {
          false
        } else {
          a_kmer <= b_kmer
        }
      }
    })
  }
}
