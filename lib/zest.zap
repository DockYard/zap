pub module Zest {
  @moduledoc = """
    Zest test framework.

    For test cases: `use Zest.Case` (provides assert/reject + describe/test DSL).
    For test runner: `use Zest.Runner` (provides summary).

    This module provides standalone assert and reject functions
    with test tracking via `:zig.TestTracker`.
    """

  @doc = """
    Asserts that a boolean value is `true`.

    On success, increments the assertion pass counter.
    On failure, increments the assertion fail and test failure
    counters, prints a red F, then panics.
    """

  pub fn assert(value :: Bool) -> String {
    assert_check(value, "assertion failed")
  }

  @doc = """
    Asserts that a boolean value is `true` with a custom message.
    """

  pub fn assert(value :: Bool, message :: String) -> String {
    assert_check(value, message)
  }

  @doc = """
    Asserts that a boolean value is `false`.
    """

  pub fn reject(value :: Bool) -> String {
    reject_check(value, "rejection failed")
  }

  @doc = """
    Asserts that a boolean value is `false` with a custom message.
    """

  pub fn reject(value :: Bool, message :: String) -> String {
    reject_check(value, message)
  }

  fn assert_check(value :: Bool, message :: String) -> String {
    if value {
      :zig.TestTracker.pass_assertion()
      "."
    } else {
      :zig.TestTracker.fail_assertion()
      :zig.TestTracker.increment_test_failures()
      :zig.TestTracker.print_fail()
      panic(message)
    }
  }

  fn reject_check(value :: Bool, message :: String) -> String {
    if not value {
      :zig.TestTracker.pass_assertion()
      "."
    } else {
      :zig.TestTracker.fail_assertion()
      :zig.TestTracker.increment_test_failures()
      :zig.TestTracker.print_fail()
      panic(message)
    }
  }
}
