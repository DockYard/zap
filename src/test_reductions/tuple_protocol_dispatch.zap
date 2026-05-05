# Reduced reproducer — protocol dispatch on values destructured
# from a tuple. The `<>` macro expands to
# `Concatenable.concat(left, right)`; the dispatcher needs the
# *exact* type of `left` to choose the impl. When `left` came from
# a tuple destructure (`{kmer, count} = pair`), the dispatcher
# fails with:
#
#   error: first argument to protocol `Concatenable` does not satisfy `Concatenable`
#     └─ protocol dispatch requires an exact protocol constraint or a concrete impl
#
# Documented in `docs/clbg-three-bench-blockers-research-brief.md` §8.3.

pub struct Probe {
  pub fn run() -> String {
    pair = {"hello", 1 :: i64}
    {a, _} = pair
    a <> " world"
  }
}
