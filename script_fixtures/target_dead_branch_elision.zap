# Phase 1 — dead-branch-elision PROOF for the comptime `@target` fold.
#
# Each NON-matching branch calls `:zig.System.zap_nonexistent_probe_xyz()`,
# a primitive that does NOT exist in the Zap runtime. A `:zig.` bridge call
# is not validated at type-check; it resolves at ZIR lowering against the
# runtime. So if a non-matching branch were NOT comptime-elided, the build
# would FAIL at the ZIR/Sema/link layer with an unresolved-symbol error.
#
# The matching branch (selected by the build's target) contains ONLY a
# plain `IO.puts`. On every target exactly one branch is live; the others
# — each carrying the bogus `:zig.` call — must be elided for the build to
# succeed. A successful build + the correct single line printed therefore
# PROVES the dead branches were folded away before ZIR lowering. This is
# the comptime-guard escape hatch the capability model (Phase 2) relies on:
# a `:zig.` call guarded by `if @target.os == :<this> { … }` compiles on
# every target because the non-matching arms never reach the resolver's
# live path.
#
# Expected: prints "elision-ok: <os>" for the build's target, exit 0.
# (If the fold regressed, the build fails with an unresolved
# `zap_nonexistent_probe_xyz` symbol instead.)

fn main(args :: [String]) -> u8 {
  if @target.os == :macos {
    IO.puts("elision-ok: macos")
  } else {
    if @target.os == :wasi {
      IO.puts("elision-ok: wasi")
    } else {
      if @target.os == :windows {
        IO.puts("elision-ok: windows")
      } else {
        if @target.os == :linux {
          IO.puts("elision-ok: linux")
        } else {
          x = :zig.System.zap_nonexistent_probe_xyz()
          IO.puts("elision-ok: other")
        }
      }
    }
  }
  0
}
