# FCC Phase 3 — Gap 2. A capturing closure whose body is an `if`-expression
# (conditional) stored in a `fn`-typed field and called. The closure-body
# desugar lowers the body into the synthesized `impl Callable.call` method;
# an `if`-expression in that body must survive the if->case lowering instead
# of reaching the HIR builder as a raw `if_expr` (`unreachable`).
#
# Root cause (fixed): the macro engine's `expandExpr` treated `struct_expr`
# (and `tuple`/`list`/`map`) as leaf nodes and never recursed into their
# child expressions, so the surface `if` inside the closure body (a
# struct-field value) skipped if->case expansion. expandExpr now recurses
# into all four container literals.
#
# This variant does NOT raise (Gap 2's raising variant is gated by Phase 4
# effect inference). It exercises the conditional-body compile path. The
# closure is built in a factory method (idiomatic FCC form).
#
# Expected (both managers): prints `7` (n=5 > 0 -> 5 + 2), exit 0.

pub struct Handler {
  action :: fn() -> i64
}

pub struct HandlerMaker {
  pub fn make(n :: i64) -> Handler {
    %Handler{ action: fn() -> i64 { if n > 0 { n + 2 } else { 1 } } }
  }
}

fn main(_args :: [String]) -> u8 {
  h = HandlerMaker.make(5)
  IO.puts(Integer.to_string(h.action()))
  0
}
