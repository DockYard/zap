# Phase 2 acceptance — the comptime-`@target` ESCAPE HATCH (the `if` form).
#
# The SAME `:terminal`-gated reference (`IO.get_char/0`) guarded by an
# `if @target.os != :wasi { … }`. The Kernel `if` macro expands this to a
# `case` over the folded comparison BEFORE type-checking, so the guarded call
# lands in a clause that is COMPTIME-DEAD on wasi. The type-checker's
# `@target`-case fold (shared with the HIR fold via `target_fold`) skips the
# dead clause, so the gated reference never reaches the gate — the build
# COMPILES for wasi (and the live `else` runs under wasmtime).
#
# This is the load-bearing portability idiom: a gate is a compile error only on
# a LIVE reference. Expected: compiles for every target; on wasi prints
# "escape-hatch-if-ok: wasi" under wasmtime; native reads a char.

fn main(args :: [String]) -> u8 {
  if @target.os != :wasi {
    c = IO.get_char()
    IO.puts(c)
  } else {
    IO.puts("escape-hatch-if-ok: wasi")
  }
  0
}
