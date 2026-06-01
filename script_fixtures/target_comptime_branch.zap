# Phase 1 — comptime `@target` introspection + dead-branch elision proof.
#
# `@target.os` is a comptime atom (the language analog of Zig's
# `builtin.os.tag`). The `if`/`else` chain folds at COMPILE time: only the
# branch matching the build's target is lowered to ZIR; the others are
# elided BEFORE ZIR lowering. This fixture proves the SELECTION is correct
# per target (the dead-branch-elision PROOF is the companion fixture
# `target_dead_branch_elision.zap`, whose dead branches contain code that
# would fail to lower if not elided).
#
# Expected stdout per target:
#   native macOS  -> "target-os: macos"
#   wasm32-wasi   -> "target-os: wasi"
#   x86_64-windows-> "target-os: windows"

fn main(args :: [String]) -> u8 {
  if @target.os == :macos {
    IO.puts("target-os: macos")
  } else {
    if @target.os == :wasi {
      IO.puts("target-os: wasi")
    } else {
      if @target.os == :windows {
        IO.puts("target-os: windows")
      } else {
        if @target.os == :linux {
          IO.puts("target-os: linux")
        } else {
          IO.puts("target-os: other")
        }
      }
    }
  }
  0
}
