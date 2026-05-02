@doc = "Compile-time probe for testing __using__ expansion."
pub struct TestProbe {
  pub macro __using__(_opts :: Expr) -> Expr {
    _ignore = _opts
    quote {
      import TestProbe

      pub fn probe_called() -> i64 {
        42
      }
    }
  }

  pub fn helper() -> i64 {
    1
  }
}
