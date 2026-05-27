# FCC Phase 5 — Item 2. A `type`-alias-named function type in a RETURN position
# whose returned closure RAISES (aliased-Callable-with-effect, capturing). The
# alias resolves to `fn(i64) -> i64`; the returned capturing closure both
# captures (`n`) and raises (`Boom`). Invoking it under `rescue` discharges the
# effect. Exercises the alias-return box decision together with effect
# inference and capture-env ARC at once.
#
# Expected (both managers): prints `202`
#   - f(3)  = 3 + 100 = 103  (no raise)
#   - f(10) raises Boom -> rescue arm -> 99
#   - 103 + 99 = 202
# exit 0, leak-free.

@code Z9603
pub error Boom {}

type RiskyAdder = fn(i64) -> i64

pub struct AliasCapRaise {
  pub fn make(n :: i64) -> RiskyAdder {
    fn(x :: i64) -> i64 {
      if x > 5 {
        raise %Boom{message: "too big"}
      }
      x + n
    }
  }
}

fn main(_args :: [String]) -> u8 {
  f = AliasCapRaise.make(100)
  ok = try {
    f(3)
  } rescue {
    e :: Boom -> 0
  }
  big = try {
    f(10)
  } rescue {
    e :: Boom -> 99
  }
  IO.puts(Integer.to_string(ok + big))
  0
}
