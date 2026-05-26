@code Z9601
pub error Boom {}

# Phase 4 scenario 5 (capturing variant of the MAP value): a CAPTURING raising
# closure as a value of a `%{Atom => fn(i64) -> i64}` map (a boxed `Callable`
# value with an ARC-managed captured env), extracted inline via `Map.get` and
# called under `rescue`. The value's boxed `Callable` instantiation carries the
# inferred `raises`, so dispatching the extracted value propagates the raise to
# the enclosing rescue, balanced under both managers. The mandatory `Map.get`
# fallback also captures (so it boxes to match the map's boxed values).
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
  handlers = %{:strict => Maker.make(5), :loose => Maker.make(100)}
  result = try {
    Map.get(handlers, :strict, Maker.make(0))(99)
  } rescue {
    e :: Boom -> 44
  }
  IO.puts(Integer.to_string(result))
  0
}
