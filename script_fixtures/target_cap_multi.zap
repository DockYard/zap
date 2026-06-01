# Phase 2 acceptance — MULTIPLE capabilities are ALL-required, and the
# diagnostic names the FIRST missing one (declaration order). `Combo.go` needs
# `:filesystem` AND `:terminal`. wasm32-wasi HAS `:filesystem` but lacks
# `:terminal`, so on wasi the gate must report the first MISSING capability
# (`:terminal`), not the satisfied `:filesystem`. On native (both present) it
# compiles + runs.
#
# Expected: native prints "combo-ok"; wasm32-wasi FAILS naming `:terminal`.

pub struct Combo {
  @available_on(:filesystem, :terminal)

  pub fn go() -> String { "combo-ok" }
}

fn main(args :: [String]) -> u8 {
  IO.puts(Combo.go())
  0
}
