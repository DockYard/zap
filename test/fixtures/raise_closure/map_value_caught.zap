@code Z9601
pub error Boom {}

# A raising closure held as a value of a `%{Atom => fn() -> i64}` map (a boxed
# `Callable` value), extracted via `Map.get` and called under `rescue`. Phase 4
# scenario 2 (MAP value): the value's boxed `Callable` instantiation carries the
# inferred `raises`, so dispatching the extracted value propagates the raise to
# the enclosing rescue. `Map.get`'s mandatory fallback is a pure closure (no
# spurious effect from the fallback).
fn main(args :: [String]) -> u8 {
  handlers = %{:ok => fn() -> i64 { 11 }, :boom => fn() -> i64 { raise %Boom{message: "from map"} }}
  result = try {
    Map.get(handlers, :boom, fn() -> i64 { 0 })()
  } rescue {
    e :: Boom -> 88
  }
  IO.puts(Integer.to_string(result))
  0
}
