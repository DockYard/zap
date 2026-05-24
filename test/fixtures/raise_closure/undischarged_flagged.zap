@code Z9601
pub error BoomError {}

pub struct Higher {
  pub fn apply(f :: ( -> i64)) -> i64 {
    f()
  }

  # `runner` declares it raises nothing (`raises ()` is the empty row via the
  # absence of any raise it admits), yet it calls `apply` with a raising
  # closure and does NOT rescue. The instantiated effect (BoomError) must be
  # flagged against the declared empty row — proving the propagated closure
  # effect is a real, discharge-checked obligation, not silently dropped.
  pub fn runner() -> i64 raises () {
    Higher.apply(fn() -> i64 { raise %BoomError{message: "leaked"} })
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    Higher.runner()
  } rescue {
    e :: BoomError -> 0
  }
  IO.puts(Integer.to_string(result))
  0
}
