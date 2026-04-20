pub module Zest {
  @moduledoc = """
    Zest test framework.

    For test cases: `use Zest.Case` (provides assert/reject + describe/test DSL).
    For test runner: `use Zest.Runner` (provides summary).

    This module provides standalone assert and reject functions
    with non-fatal test tracking via `:zig.TestTracker`. Failed
    assertions mark the current test as failed and return "F"
    but do not stop execution.
    """

  @doc = """
    Asserts that a boolean value is `true`.

    On success, increments the assertion pass counter and
    returns ".". On failure, increments the assertion fail
    counter and returns "F". Execution continues (non-fatal).
    """

  pub fn assert(value :: Bool) -> String {
    assert_check(value, "assertion failed")
  }

  @doc = """
    Asserts that a boolean value is `true` with a custom message.

    On success, increments the assertion pass counter and
    returns ".". On failure, increments the assertion fail
    counter and returns "F". Execution continues (non-fatal).
    """

  pub fn assert(value :: Bool, message :: String) -> String {
    assert_check(value, message)
  }

  @doc = """
    Asserts that a boolean value is `false`.

    On success, increments the assertion pass counter and
    returns ".". On failure, increments the assertion fail
    counter and returns "F". Execution continues (non-fatal).
    """

  pub fn reject(value :: Bool) -> String {
    reject_check(value, "rejection failed")
  }

  @doc = """
    Asserts that a boolean value is `false` with a custom message.

    On success, increments the assertion pass counter and
    returns ".". On failure, increments the assertion fail
    counter and returns "F". Execution continues (non-fatal).
    """

  pub fn reject(value :: Bool, message :: String) -> String {
    reject_check(value, message)
  }

  fn assert_check(value :: Bool, _message :: String) -> String {
    if value {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion()
      "F"
    }
  }

  fn reject_check(value :: Bool, _message :: String) -> String {
    if not value {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion()
      "F"
    }
  }
}
