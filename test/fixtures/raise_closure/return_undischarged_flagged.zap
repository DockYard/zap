@code Z9601
pub error BoomError {}

# Phase 4 scenario 3 (undischarged flagging — RETURN position): a function that
# obtains a raising closure FROM A RETURN and INVOKES it WITHOUT a `rescue`, in a
# function whose declared `raises ()` row (empty) does not admit the closure's
# effect, MUST be FLAGGED — exactly like a direct undischarged raise. This proves
# the returned closure's effect is a real, discharge-checked obligation, not
# silently dropped.
pub struct Maker {
  pub fn make() -> fn() -> i64 {
    fn() -> i64 { raise %BoomError{message: "leaked from returned closure"} }
  }

  # Declares it raises nothing, yet invokes a returned raising closure without
  # rescuing. The instantiated effect (BoomError) must be flagged against the
  # declared empty row.
  pub fn runner() -> i64 raises () {
    action = Maker.make()
    action()
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    Maker.runner()
  } rescue {
    e :: BoomError -> 0
  }
  IO.puts(Integer.to_string(result))
  0
}
