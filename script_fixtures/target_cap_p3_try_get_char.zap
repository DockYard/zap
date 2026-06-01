# Phase 3 acceptance — DIRECT (unguarded) reference to the swept
# `:terminal`-gated API `IO.try_get_char/0` (non-blocking raw-mode read,
# gated `@available_on(:terminal)` in lib/io.zap as part of the Phase 3
# stdlib sweep). Isolated to ONE gated API so the diagnostic names it exactly.
#
# On a target WITHOUT `:terminal` (wasm32-wasi, whose runtime has no termios,
# so raw mode is a no-op and a "key available right now" probe is meaningless)
# this MUST be a clean COMPILE-TIME `target_capability` error naming the
# `:terminal` capability — NOT a silent no-op at runtime. On native (which has
# `:terminal`) it compiles + runs exactly as before (returns "" immediately on
# a non-interactive stdin).
#
# Expected: native compiles + runs; wasm32-wasi FAILS to compile with the
# `:terminal` capability diagnostic.

fn main(args :: [String]) -> u8 {
  key = IO.try_get_char()
  IO.puts("try-get-char-ok")
  0
}
