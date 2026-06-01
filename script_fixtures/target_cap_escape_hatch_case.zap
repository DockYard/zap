# Phase 2 acceptance — the comptime-`@target` ESCAPE HATCH (the direct `case`
# form). The same `:terminal`-gated reference inside a `_` clause of a
# `case @target.os { … }`. On wasi the `:wasi` clause is live and the `_`
# clause (holding the gated `IO.get_char/0`) is comptime-dead, so the
# type-checker's atom-scrutinee `@target`-case fold skips it and the build
# COMPILES. Proves the escape hatch works for the direct-`case` shape too, not
# only the desugared-`if` shape.
#
# Expected: compiles for every target; on wasi prints "escape-hatch-case-ok:
# wasi" under wasmtime.

fn main(args :: [String]) -> u8 {
  case @target.os {
    :wasi -> IO.puts("escape-hatch-case-ok: wasi")
    _ -> {
      c = IO.get_char()
      IO.puts(c)
    }
  }
  0
}
