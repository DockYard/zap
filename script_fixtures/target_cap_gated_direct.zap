# Phase 2 acceptance — a DIRECT (unguarded) reference to a `:terminal`-gated
# stdlib API (`IO.get_char/0`, gated `@available_on(:terminal)` in lib/io.zap).
#
# On a target WITHOUT `:terminal` (wasm32-wasi, whose runtime has no termios)
# this MUST be a clean COMPILE-TIME `target_capability` error naming the
# `:terminal` capability and the `@target` guard hint — NOT "undefined", and
# NOT a runtime trap. On a target WITH `:terminal` (native) it compiles and
# behaves exactly as before (zero cost; the attribute is comptime-erased).
#
# Expected: native compiles + runs (reads one char from stdin); wasm32-wasi
# FAILS to compile with the `:terminal` capability diagnostic.

fn main(args :: [String]) -> u8 {
  c = IO.get_char()
  IO.puts(c)
  0
}
