# Cross-struct fixture for audit finding zirb-2--02: an arity-1 clause with
# NO defaults coexisting with a defaults-bearing arity-3 clause of the same
# name. A cross-struct call resolved to `pick/1` must not be hijacked into
# `pick/3` by the ZIR default-argument inlining scan.
pub struct DefaultParamsOverloadHelper {
  pub fn pick(a :: i64) -> i64 {
    a * 1000
  }

  pub fn pick(a :: i64, b :: i64 = 2, c :: i64 = 3) -> i64 {
    a + b + c
  }
}
