@code Z9601
pub error BoomError {}

pub struct Direct {
  # A raising closure invoked through call_closure (the closure value is
  # a parameter). The raise propagates through `invoke` to its caller and is
  # caught by the enclosing `rescue`. `invoke`'s effect row is polymorphic
  # over its closure parameter's effect — inferred, no annotation.
  pub fn invoke(f :: ( -> i64)) -> i64 {
    f()
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    Direct.invoke(fn() -> i64 { raise %BoomError{message: "direct boom"} })
  } rescue {
    e :: BoomError -> 7
  }
  IO.puts(Integer.to_string(result))
  0
}
