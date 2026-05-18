@doc = """
  Zest test framework.

  For test cases: `use Zest.Case` provides the `test/case` DSL plus
  macro-backed `assert` and `reject`.

  For test runners: `use Zest.Runner` provides test discovery and
  summary reporting.

  This struct keeps standalone `Zest.assert` and `Zest.reject`
  compatibility for callers that use the assertion tracker directly.
  The richer source-aware assertion diagnostics live in `Zest.Case`.
  """

pub struct Zest {
  @doc = """
    Asserts that a boolean value is `true`.

    On success, increments the assertion pass counter and returns ".".
    On failure, increments the assertion fail counter, records a
    message, and returns "F".
    """

  pub fn assert(value :: Bool) -> String {
    assert_check(value, "assertion failed")
  }

  @doc = """
    Asserts that a boolean value is `true` with a custom message.

    On success, increments the assertion pass counter and returns ".".
    On failure, increments the assertion fail counter, records the
    message, and returns "F".
    """

  pub fn assert(value :: Bool, message :: String) -> String {
    assert_check(value, message)
  }

  @doc = """
    Asserts that a boolean value is `false`.

    On success, increments the assertion pass counter and returns ".".
    On failure, increments the assertion fail counter, records a
    message, and returns "F".
    """

  pub fn reject(value :: Bool) -> String {
    reject_check(value, "rejection failed")
  }

  @doc = """
    Asserts that a boolean value is `false` with a custom message.

    On success, increments the assertion pass counter and returns ".".
    On failure, increments the assertion fail counter, records the
    message, and returns "F".
    """

  pub fn reject(value :: Bool, message :: String) -> String {
    reject_check(value, message)
  }

  fn assert_check(value :: Bool, message :: String) -> String {
    if value {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion_with_message(message)
      "F"
    }
  }

  fn reject_check(value :: Bool, message :: String) -> String {
    if not value {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion_with_message(message)
      "F"
    }
  }
}
