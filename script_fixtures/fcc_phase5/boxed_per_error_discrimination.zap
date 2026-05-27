# FCC Phase 5 — Item 3(a). Per-error-type rescue discrimination on the BOXED
# `Callable` path is PRECISE: two DISTINCT error types (`AlphaErr`, `BetaErr`)
# raised by two boxed closures that share ONE `Callable({i64}, i64)`
# instantiation (stored in the same `fn`-typed field) are correctly
# discriminated by their specific `rescue` arms — and each arm binds `e` to its
# SPECIFIC error type, so type-specific field access (`e.detail` on AlphaErr,
# `e.code` on BetaErr) resolves precisely. The per-instantiation `raises` JOIN
# governs only whether the vtable slot is error-union'd (a sound coarse bool);
# the value-level rescue matching recovers full per-error precision.
#
# Expected (both managers): prints
#   alpha-detail
#   7
# exit 0, leak-free.

@code Z9611
pub error AlphaErr {
  detail :: String
}

@code Z9612
pub error BetaErr {
  code :: i64
}

pub struct Holder {
  op :: fn(i64) -> i64
}

pub struct PErr {
  pub fn alpha() -> Holder {
    %Holder{op: fn(_x :: i64) -> i64 { raise %AlphaErr{message: "a", detail: "alpha-detail"} }}
  }

  pub fn beta() -> Holder {
    %Holder{op: fn(_x :: i64) -> i64 { raise %BetaErr{message: "b", code: 7} }}
  }

  pub fn describe(h :: Holder) -> String {
    try {
      _n = h.op(1)
      "no-raise"
    } rescue {
      e :: AlphaErr -> e.detail
      e :: BetaErr -> Integer.to_string(e.code)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(PErr.describe(PErr.alpha()))
  IO.puts(PErr.describe(PErr.beta()))
  0
}
