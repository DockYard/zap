@code Z9601
pub error Boom {}

# A raising closure stored in a `fn() -> i64` struct field, constructed by a
# factory method, then loaded and called under `rescue`. Phase 4 (effect by
# inference): the closure body raises, so its `Callable.call` carries
# `error{ZapRaise}!i64`, the field-load `Callable` type carries the inferred
# `raises`, and calling it propagates the raise to the enclosing rescue.
pub struct Handler {
  action :: fn() -> i64
}

pub struct Maker {
  pub fn make() -> Handler {
    %Handler{ action: fn() -> i64 { raise %Boom{message: "x"} } }
  }
}

fn main(args :: [String]) -> u8 {
  h = Maker.make()
  result = try {
    h.action()
  } rescue {
    e :: Boom -> 99
  }
  IO.puts(Integer.to_string(result))
  0
}
