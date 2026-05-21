# Round 2 Blocker A end-to-end fixture (script mode).
#
# Exercises the construction-side fix from round 2:
#   1. `Option(i64).Some(42)` and `Option(i64).None` materialise as
#      `@unionInit(Option_i64, "<Variant>", payload)` regardless of
#      where the construction happens — non-return-position locals,
#      call arguments, discard sites, etc.
#   2. The destructure side observes the union's `activeTag` and
#      extracts the payload via the per-instantiation type layout.
#
# The scrutinee is passed as a RUNTIME parameter (rather than bound
# to a local from a comptime-known construction) to defeat Zig's
# comptime folding of constant-discriminant matches — comptime
# folding evaluates BOTH arms against the same constant union value,
# which trips a pre-existing pattern-match limitation when one arm
# accesses an inactive variant's payload. That comptime fold is
# orthogonal to round 2 Blocker A; for the end-to-end repro of the
# construction-side fix this fixture takes the variant through a
# function-parameter boundary, which forces the discriminant to
# runtime and decouples the two layers cleanly.
#
# Before round 2 this script fails at the ZIR layer with
# 'expected enum or union type, found ...struct...' (the
# `struct_init_anon` fallback). After round 2 the fixture prints:
#
#   42
#   0
#
# Then exits with code 0.

pub struct Demo {
  pub fn unwrap(opt :: Option(i64)) -> i64 {
    case opt {
      Option.Some(v) -> v
      Option.None -> 0
    }
  }
}

fn main(_args :: [String]) -> u8 {
  Kernel.inspect(Demo.unwrap(Option(i64).Some(42)))
  Kernel.inspect(Demo.unwrap(Option(i64).None))
  0
}
