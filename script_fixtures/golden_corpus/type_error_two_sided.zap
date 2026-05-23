# Golden corpus — a two-sided type error (domain=type, TypeProvenance).
#
# The body produces a `String` but the function is declared to return `i64`.
# The renderer shows BOTH sides: the offending value's type and the declared
# return type's provenance (`return type i64 declared here`).
pub struct TypeErrorTwoSided {
  pub fn wrong() -> i64 {
    "not an integer"
  }
}

fn main(_args :: [String]) -> u8 {
  TypeErrorTwoSided.wrong()
}
