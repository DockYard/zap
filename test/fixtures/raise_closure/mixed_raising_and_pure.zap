@code Z9601
pub error BoomError {}

pub struct Mixed {
  # The crux of per-instance effect specialization: the SAME higher-order
  # function `apply/1` is invoked with BOTH a raising closure and a pure
  # closure in one program. Each call site must resolve to a DISTINCT
  # monomorphized instance — the raising instance returns `error{ZapRaise}!T`
  # and propagates, the pure instance returns plain `T` and never raises.
  pub fn apply(f :: fn() -> i64) -> i64 {
    f()
  }
}

fn main(args :: [String]) -> u8 {
  # Pure-closure instance: runs cleanly, no rescue needed.
  pure_result = Mixed.apply(fn() -> i64 { 21 + 21 })
  IO.puts(Integer.to_string(pure_result))

  # Raising-closure instance: the raise propagates through `apply` and is
  # caught by the enclosing rescue. Distinct instance from the pure call.
  raising_result = try {
    Mixed.apply(fn() -> i64 { raise %BoomError{message: "mixed boom"} })
  } rescue {
    e :: BoomError -> 7
  }
  IO.puts(Integer.to_string(raising_result))
  0
}
