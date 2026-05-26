@code Z9601
pub error Boom {}

# Phase 4 scenario 4 (mixed / effect-parametric by inference): the SAME
# `fn() -> i64` field type holds a RAISING closure in one Handler instance and a
# PURE closure in another. Boxing erases the concrete impl, so the field's boxed
# `Callable` instantiation carries the conservative JOIN — it surfaces
# `error{ZapRaise}!i64` because it ADMITS a raiser. The pure instance's adapter
# coerces its payload into the union for free (returns 42 cleanly under rescue);
# the raising instance propagates to rescue. Both behave correctly; the join is
# an accepted over-approximation (a pure-only program of this field type would
# gain NO error union — see pure_field_no_rescue).
pub struct Handler {
  action :: fn() -> i64
}

pub struct Maker {
  pub fn raising() -> Handler {
    %Handler{ action: fn() -> i64 { raise %Boom{message: "boom"} } }
  }

  pub fn pure() -> Handler {
    %Handler{ action: fn() -> i64 { 42 } }
  }
}

fn main(args :: [String]) -> u8 {
  raising_handler = Maker.raising()
  pure_handler = Maker.pure()

  raising_result = try {
    raising_handler.action()
  } rescue {
    e :: Boom -> 7
  }
  IO.puts(Integer.to_string(raising_result))

  # The pure instance flows through the SAME error-union'd slot (the join), but
  # its adapter returns a plain payload that coerces — caught arm never fires.
  pure_result = try {
    pure_handler.action()
  } rescue {
    e :: Boom -> 0
  }
  IO.puts(Integer.to_string(pure_result))
  0
}
