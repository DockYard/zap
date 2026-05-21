# Round 2 Blocker A end-to-end fixture (script mode) — multi-arg parametric union.
#
# Verifies that the consistent threading rule for `union_init` extends
# beyond single-type-arg unions: `Result(i64, String).Ok(42)` and
# `Result(i64, String).Err("bad")` materialise as
# `@unionInit(Result_i64_String, "Ok"|"Err", payload)`, the
# per-instantiation type's synthetic Zig file from step 3.6 carries
# both substituted payload types (`i64` and `[]const u8`), and the
# destructure side reads the active variant via `activeTag`.
#
# Scrutinee threads through a function parameter to keep the
# discriminant runtime — same rationale as
# `blocker_a_option_destructure.zap`'s header comment.
#
# Expected output:
#
#   42
#   -1
#
# Exit code 0.

pub union Result(t, e) {
  Ok :: t
  Err :: e
}

pub struct Demo {
  pub fn unwrap_ok(r :: Result(i64, String)) -> i64 {
    case r {
      Result.Ok(v) -> v
      Result.Err(_) -> -1
    }
  }
}

fn main(_args :: [String]) -> u8 {
  Kernel.inspect(Demo.unwrap_ok(Result(i64, String).Ok(42)))
  Kernel.inspect(Demo.unwrap_ok(Result(i64, String).Err("bad")))
  0
}
