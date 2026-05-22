# Phase 2.d acceptance: defer/errdefer interleaving on ONE LIFO stack
# (Zig's model). Source order: `defer A`, `errdefer B`, `defer C`.
#
#   * success path runs C, A   (B is errdefer -> skipped)
#   * error   path runs C, B, A (full reverse unwind)
#
# Expected output:
#
#   error:
#   C
#   B
#   A
#   done
#   success:
#   C
#   A
#   ok

pub struct Interleave {
  pub fn step(n :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> Result(i64, String).Ok(n - 1)
      false -> Result(i64, String).Error("stop")
    }
  }

  pub fn run(n :: i64) -> Result(i64, String) {
    defer IO.puts("A")
    errdefer IO.puts("B")
    defer IO.puts("C")
    next = Interleave.step(n)?
    Result(i64, String).Ok(next)
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts("error:")
  case Interleave.run(0) {
    Result.Ok(_v) -> IO.puts("ok")
    Result.Error(_r) -> IO.puts("done")
  }
  IO.puts("success:")
  case Interleave.run(1) {
    Result.Ok(_v) -> IO.puts("ok")
    Result.Error(_r) -> IO.puts("done")
  }
  0
}
