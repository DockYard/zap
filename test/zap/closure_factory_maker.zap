@doc = """
  Helper factory for `closure_devirt_test.zap`. A Zest test file must declare
  exactly one struct, so the closure-producing helpers that the devirtualized
  dispatch corpus exercises live here.

  `non_capturing_op/0` RETURNS a NON-capturing `fn(i64) -> i64` whose runtime
  representation stays a bare `*const fn(..)` code pointer (devirtualized, never
  boxed). Reading it back at the call boundary is the "Gap E" materialized-value
  case (`call_closure` `callee_is_bare_fn_value` -> direct `call_ref`).
  """

pub struct Zap.ClosureFactoryMaker {
  @doc = """
    A non-capturing `fn(i64) -> i64` returned by value. Non-capturing => bare
    function pointer (`ZigType.function`), the devirtualized representation.
    """

  pub fn non_capturing_op() -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x * 3 }
  }
}
