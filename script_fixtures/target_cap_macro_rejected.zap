# Phase 2 acceptance — `@available_on` on a MACRO is a category error on every
# target. A macro is compile-time-only (always runs on the host); it has no
# per-target runtime form to gate. The capability a macro's EXPANSION needs is
# gated automatically through the expanded `def`/`:zig.` reference. So a
# macro-level `@available_on` must be rejected with a redirecting diagnostic,
# NOT silently ignored (a footgun) and NOT the retired-`@requires` rejection.
#
# Expected: fails to compile on every target with "cannot gate a macro".

pub struct MacMod {
  @available_on(:terminal)

  pub macro identity(x :: Expr) -> Expr {
    quote { unquote(x) }
  }
}

fn main(args :: [String]) -> u8 {
  y = MacMod.identity(5)
  IO.puts("never")
  0
}
