# Phase 3 acceptance — the comptime-`@target` ESCAPE HATCH applied to the
# newly-swept `:terminal`-gated APIs (`IO.mode/1`, `IO.mode/2`,
# `IO.try_get_char/0`). All three live references sit inside
# `if @target.os != :wasi { … }`, so on wasi they land in a COMPTIME-DEAD
# clause that the `@target` fold elides before type-checking — the gated
# references never reach the gate, and the build COMPILES for wasi (the live
# `else` runs under wasmtime). On native the real terminal path runs.
#
# This proves the escape hatch covers the Phase 3 sweep, not just the Phase 2
# `IO.get_char/0`: a gate is a compile error only on a LIVE reference.
#
# Expected: compiles for every target; on wasi prints "p3-escape-hatch-ok: wasi"
# under wasmtime; native exercises the raw-mode terminal path.

fn main(args :: [String]) -> u8 {
  if @target.os != :wasi {
    IO.mode(IO.Mode.Raw)
    key = IO.try_get_char()
    IO.mode(IO.Mode.Normal)
    IO.mode(IO.Mode.Raw, fn() -> String {
      IO.puts("p3-escape-hatch-native")
    })
  } else {
    IO.puts("p3-escape-hatch-ok: wasi")
  }
  0
}
