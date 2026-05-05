# Reduced reproducer — a function whose body is an `if/else`
# expression where every branch is an `i64` integer literal
# triggers `value with comptime-only type 'comptime_int' depends
# on runtime control flow` from the Zig backend.
#
# Each branch is annotated with `:: i64`, so the surface syntax
# carries enough type information for ZIR emission to choose
# `i64`. The compiler currently emits a `select`/branch result
# that the Zig stage sees as `comptime_int`, blowing up before
# the function can be lowered.
#
# Surfaced while porting the CLBG `k-nucleotide` benchmark (see
# `~/projects/lang-benches/k-nucleotide/k_nucleotide.zap`). The
# multi-clause `pub fn base_code("A") -> i64 { 0 :: i64 }` shape
# *does* compile, so this only blocks the if/else style. Both
# paths read identically at the source level, so the if/else
# version should also lower to a typed `i64` value.

pub struct IfElseIntLiteralBranches {
  pub fn base_code(byte :: String) -> i64 {
    if byte == "A" {
      0 :: i64
    } else {
      -1 :: i64
    }
  }

  pub fn run() -> i64 {
    IfElseIntLiteralBranches.base_code("A")
  }
}
