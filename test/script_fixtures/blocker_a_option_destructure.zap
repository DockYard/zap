# Round 2 Blocker A fixture (script mode).
#
# Constructs an Option(i64).Some(42) in non-return position, binds it to
# a local, then destructures via `case`. Round 1's ZIR builder falls
# back to `struct_init_anon` here, producing an anonymous struct that
# `activeTag`-based pattern matching rejects. After Round 2 the
# `union_init` emission must always carry the per-instantiation union
# type (`Option_i64`) regardless of the enclosing function's return
# type — so this script must compile and print:
#
#   42
#   0
#
# Then exit with code 0.

pub struct Demo {
  pub fn unwrap_some() -> i64 {
    opt = Option(i64).Some(42)
    case opt {
      Option.Some(v) -> v
      Option.None -> 0
    }
  }

  pub fn unwrap_none() -> i64 {
    opt = Option(i64).None
    case opt {
      Option.Some(v) -> v
      Option.None -> 0
    }
  }
}

fn main(_args :: [String]) -> u8 {
  Kernel.inspect(Demo.unwrap_some())
  Kernel.inspect(Demo.unwrap_none())
  0
}
