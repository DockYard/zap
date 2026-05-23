@code Z9601
pub error NegError {}

pub struct Validator {
  pub fn ensure_positive(n :: i64) -> i64 raises NegError {
    case n {
      0 -> raise %NegError{message: "zero is not positive"}
      _ -> n
    }
  }

  # Effect-polymorphism through the iteration combinator: the
  # for-comprehension lifts a `__for_N` synthetic helper that invokes the
  # raising `ensure_positive` directly. The helper's inferred `raises` row
  # picks up NegError (an implicit `?` at every call site), so the helper
  # returns `error{ZapRaise}![i64]`, its call sites unwrap-and-propagate, and
  # the enclosing `try`/`rescue` discharges it — with NO per-error-type
  # specialization of the comprehension. A pure body leaves the helper pure.
  pub fn validate_all(inputs :: [i64]) -> String {
    try {
      validated = for n <- inputs { ensure_positive(n) }
      "all positive"
    } rescue {
      e :: NegError -> "found a non-positive"
    }
  }
}

fn main(args :: [String]) -> u8 {
  IO.puts(Validator.validate_all([1, 0, 3]))
  0
}
