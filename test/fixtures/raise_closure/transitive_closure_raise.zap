@code Z9601
pub error BoomError {}

pub struct Transitive {
  # `apply` invokes its closure parameter. The closure passed to it is a
  # PURE-looking wrapper whose body invokes ANOTHER closure (`inner`) that
  # raises. The effect must propagate transitively: the wrapper closure is
  # itself raising (because it invokes a raising closure), so `apply`'s
  # instance is raising too, and the raise surfaces at apply's call site.
  pub fn apply(f :: ( -> i64)) -> i64 {
    f()
  }

  pub fn call_inner(g :: ( -> i64)) -> i64 {
    g()
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    Transitive.apply(fn() -> i64 {
      Transitive.call_inner(fn() -> i64 { raise %BoomError{message: "deep"} })
    })
  } rescue {
    e :: BoomError -> 55
  }
  IO.puts(Integer.to_string(result))
  0
}
