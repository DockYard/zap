pub module Zest.Runtime {
  # Test framework runtime — tracks pass/fail counts and output.
  # These functions are implemented in ZestRuntime (src/runtime.zig)
  # and bound via @native attributes.

  @native = "ZestRuntime.reset"
  pub fn reset() -> String

  @native = "ZestRuntime.begin_test"
  pub fn begin_test() -> String

  @native = "ZestRuntime.fail"
  pub fn fail(_message :: String) -> String

  @native = "ZestRuntime.end_test"
  pub fn end_test(_name :: String) -> String

  @native = "ZestRuntime.run_test"
  pub fn run_test(_name :: String, _test_passed :: Bool) -> String

  @native = "ZestRuntime.summary"
  pub fn summary() -> String

  @native = "ZestRuntime.begin_describe"
  pub fn begin_describe(_name :: String) -> String

  @native = "ZestRuntime.end_describe"
  pub fn end_describe() -> String
}
