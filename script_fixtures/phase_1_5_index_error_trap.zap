# Phase 1.5 acceptance: out-of-bounds list index TRAPS as an index_error.
#
# Indexing a list outside its `0..length` range aborts with the
# canonical Zap index-error shape and a non-zero exit — the same
# observable behavior as `raise %IndexError{...}`.
#
# Expected: stderr contains `** (index_error)` and exit code is
# non-zero. This fixture never reaches the `0` return.

pub struct Bounds {
  pub fn read_oob(items :: List(i64)) -> i64 {
    # index 5 into a 3-element list — out of bounds.
    List.get(items, 5)
  }
}

fn main(_args :: [String]) -> u8 {
  items = [10, 20, 30]
  value = Bounds.read_oob(items)
  IO.puts(Integer.to_string(value))
  0
}
