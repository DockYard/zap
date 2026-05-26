# FCC Phase 3 — Gap 2. A capturing closure whose body is an `if`-expression
# (conditional) stored in a `fn`-typed field and called. The closure-body
# desugar lowers the body into the synthesized `impl Callable.call` method;
# an `if`-expression in that body must survive the if->case lowering (it is
# rebuilt during desugar AFTER macro expansion, so the synthesized method
# body must itself be lowered) instead of reaching the HIR builder as a raw
# `if_expr` (which is `unreachable`).
#
# This variant does NOT raise (Gap 2's raising variant is gated by Phase 4
# effect inference). It exercises the conditional-body compile path.
#
# Expected (both managers): prints `7` (n=5 > 0 -> 5 + 2), exit 0.

pub struct Handler {
  action :: fn() -> i64
}

fn main(_args :: [String]) -> u8 {
  n = 5
  h = %Handler{ action: fn() -> i64 { if n > 0 { n + 2 } else { 1 } } }
  IO.puts(Integer.to_string(h.action()))
  0
}
