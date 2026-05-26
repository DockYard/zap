@code Z9601
pub error Boom {}

# A CAPTURING raising closure RETURNED from a `fn(i64) -> i64`-returning
# function, then called under `rescue`. Phase 4 scenario 5 (capturing variant of
# the RETURN position): the returned closure captures `base` and raises, so the
# returned `fn(i64) -> i64` carries the inferred `raises` and calling it
# propagates the raise to the enclosing rescue. A capturing closure that escapes
# is boxed (ARC-managed env), so this also exercises the boxed-Callable return
# representation carrying the effect.
pub struct Maker {
  pub fn make(base :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 {
      if x > base {
        raise %Boom{message: "too big"}
      } else {
        x + base
      }
    }
  }
}

fn main(args :: [String]) -> u8 {
  adder = Maker.make(10)
  result = try {
    adder(99)
  } rescue {
    e :: Boom -> 77
  }
  IO.puts(Integer.to_string(result))
  0
}
