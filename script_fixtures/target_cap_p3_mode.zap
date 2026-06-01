# Phase 3 acceptance — DIRECT reference to the swept `:terminal`-gated API
# `IO.mode/1` (the raw/normal terminal-mode switch, gated
# `@available_on(:terminal)` in lib/io.zap). `IO.mode/1` carries the gate
# attribute directly.
#
# On a target WITHOUT `:terminal` (wasm32-wasi: no termios, so a mode switch is
# a silent no-op that breaks the documented raw/normal contract) this MUST be a
# clean COMPILE-TIME `target_capability` error naming `:terminal`. On native it
# compiles + runs (enters raw mode, restores normal).
#
# Expected: native compiles + runs; wasm32-wasi FAILS to compile naming
# `IO.mode/1` + the `:terminal` capability.

fn main(args :: [String]) -> u8 {
  IO.mode(IO.Mode.Raw)
  IO.mode(IO.Mode.Normal)
  IO.puts("mode-ok")
  0
}
