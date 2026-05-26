@code Z9601
pub error Boom {}

# A raising closure RETURNED from a `fn() -> i64`-returning function, then called
# under `rescue`. Phase 4 scenario 1 (RETURN position): the returned closure's
# body raises, so the `fn() -> i64` RETURN TYPE must carry the inferred `raises`
# (lowering to the error-union'd fn-ptr `*const fn () anyerror!i64`), and calling
# the returned closure propagates the raise to the enclosing rescue.
pub struct Maker {
  pub fn make() -> fn() -> i64 {
    fn() -> i64 { raise %Boom{message: "x"} }
  }
}

fn main(args :: [String]) -> u8 {
  action = Maker.make()
  result = try {
    action()
  } rescue {
    e :: Boom -> 99
  }
  IO.puts(Integer.to_string(result))
  0
}
