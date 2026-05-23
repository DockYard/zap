# Golden corpus — an out-of-bounds list index (domain=panic,
# sub_kind=index_error).
#
# `List.get` on an index past the end traps with the canonical
# `** (index_error) List.get: index out of bounds` shape and a symbolized
# backtrace.
pub struct IndexError {
  pub fn read_past_end() -> i64 {
    items = [10, 20, 30]
    List.get(items, 99)
  }
}

fn main(_args :: [String]) -> u8 {
  IndexError.read_past_end()
  0
}
