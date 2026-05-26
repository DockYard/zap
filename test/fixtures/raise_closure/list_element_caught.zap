@code Z9601
pub error Boom {}

# A raising closure held as an element of a `[fn() -> i64]` list (a boxed
# `Callable` element), extracted via `List.get` and called under `rescue`. Phase
# 4 scenario 2 (LIST element): the element's boxed `Callable` instantiation
# carries the inferred `raises`, so dispatching the extracted element propagates
# the raise to the enclosing rescue.
fn main(args :: [String]) -> u8 {
  actions = [fn() -> i64 { 11 }, fn() -> i64 { raise %Boom{message: "from list"} }]
  result = try {
    List.get(actions, 1)()
  } rescue {
    e :: Boom -> 88
  }
  IO.puts(Integer.to_string(result))
  0
}
