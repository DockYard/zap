@code Z9601
pub error BoomError {}

pub struct Higher {
  # Higher-order user function: invokes its closure parameter through
  # call_closure. apply/1 is effect-polymorphic by inference — invoking it
  # with a raising closure surfaces that closure's `raises` at apply's call
  # site, where the enclosing `rescue` discharges it.
  pub fn apply(f :: ( -> i64)) -> i64 {
    f()
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    Higher.apply(fn() -> i64 { raise %BoomError{message: "boom from closure"} })
  } rescue {
    e :: BoomError -> 99
  }
  IO.puts(Integer.to_string(result))
  0
}
