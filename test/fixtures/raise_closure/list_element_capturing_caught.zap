@code Z9601
pub error Boom {}

# Phase 4 scenario 5 (capturing variant of the LIST element): a CAPTURING
# raising closure as an element of a `[fn(i64) -> i64]` list (a boxed `Callable`
# element with an ARC-managed captured env), extracted inline via `List.get` and
# called under `rescue`. The element's boxed `Callable` instantiation carries the
# inferred `raises`, so dispatching the extracted element propagates the raise to
# the enclosing rescue, balanced under both managers.
pub struct Maker {
  pub fn make(limit :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 {
      if x > limit {
        raise %Boom{message: "over limit"}
      } else {
        x + limit
      }
    }
  }
}

fn main(args :: [String]) -> u8 {
  actions = [Maker.make(5), Maker.make(10)]
  result = try {
    List.get(actions, 0)(99)
  } rescue {
    e :: Boom -> 66
  }
  IO.puts(Integer.to_string(result))
  0
}
