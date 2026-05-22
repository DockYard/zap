# Phase 2.d acceptance: `defer` is BLOCK-scoped (Zig's model). A defer
# inside an inner block (here, an `if` body) runs at THAT block's exit,
# before control returns to the enclosing scope; the function-level
# defer runs last at function exit.
#
# Zap's user-facing inner block scopes are `if`/`else` bodies and
# `case`/`cond` arm bodies (each a statement list). A free-standing
# `{ ... }` block-expression is not Zap surface syntax, so block scope
# is demonstrated through an `if` body.
#
# Expected output:
#
#   in-if
#   if-exit
#   after-if
#   fn-exit

pub struct BlockScope {
  pub fn run(n :: i64) -> u8 {
    defer IO.puts("fn-exit")
    if n > 0 {
      defer IO.puts("if-exit")
      IO.puts("in-if")
    } else {
      IO.puts("in-else")
    }
    IO.puts("after-if")
    0
  }
}

fn main(_args :: [String]) -> u8 {
  BlockScope.run(1)
}
