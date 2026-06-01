# Phase 3 acceptance — ARITY BROADCAST over the swept gate. `IO.mode/2` (the
# callback form) is NOT annotated with `@available_on` directly in lib/io.zap;
# only `IO.mode/1` carries the attribute. The collector's
# `broadcastAvailableOnAcrossArities` copies the gate to EVERY arity of the
# name, so `IO.mode/2` is gated too — a caller cannot reach the termios switch
# through the other arity on a target the runtime cannot serve.
#
# On wasm32-wasi this MUST fail to compile naming `IO.mode/2` + `:terminal`,
# proving the Phase 3 gate is broadcast (not bypassable via the un-annotated
# arity). On native it compiles + runs (raw mode around the callback).
#
# Expected: native compiles + runs; wasm32-wasi FAILS to compile naming
# `IO.mode/2` + the `:terminal` capability.

fn main(args :: [String]) -> u8 {
  result = IO.mode(IO.Mode.Raw, fn() -> String {
    IO.puts("inside-callback")
  })
  IO.puts("mode-callback-ok")
  0
}
