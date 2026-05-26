@code Z9601

# A PURE closure stored in a `fn() -> i64` field and called WITHOUT any
# `rescue`. Phase 4 item #4: a pure closure contributes no `raises`, so its
# `Callable.call` stays pure `i64` (no spurious error union) and the call site
# needs no `rescue`. No spurious raises requirement.
pub struct Handler {
  action :: fn() -> i64
}

pub struct Maker {
  pub fn make() -> Handler {
    %Handler{ action: fn() -> i64 { 21 + 21 } }
  }
}

fn main(args :: [String]) -> u8 {
  h = Maker.make()
  result = h.action()
  IO.puts(Integer.to_string(result))
  0
}
