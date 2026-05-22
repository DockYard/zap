# Phase 2.d acceptance: `defer` runs at scope exit in reverse (LIFO)
# registration order on the normal-return path.
#
# Source order: defer A, defer B. At function exit they unwind in
# reverse, so B runs before A. The body's "body" line prints first.
#
# Expected output:
#
#   body
#   defer-B
#   defer-A

pub struct DeferLifo {
  pub fn run() -> u8 {
    defer IO.puts("defer-A")
    defer IO.puts("defer-B")
    IO.puts("body")
    0
  }
}

fn main(_args :: [String]) -> u8 {
  DeferLifo.run()
}
