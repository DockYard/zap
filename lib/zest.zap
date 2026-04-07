pub module Zest {
  @moduledoc = """
    Zest test framework.

    For test cases: `use Zest.Case` (provides assert/reject + describe/test DSL).
    For test runner: `use Zest.Runner` (provides run).

    This module provides legacy compatibility — `use Zest` makes
    assert/reject available directly.
    """

  @doc = """
    Asserts that a boolean value is `true`. Panics on failure.
    """
  pub fn assert(value :: Bool) -> String {
    case value {
      true -> "."
      false -> panic("assertion failed")
    }
  }

  @doc = """
    Asserts that a boolean value is `true` with a custom failure message.
    """
  pub fn assert(value :: Bool, message :: String) -> String {
    case value {
      true -> "."
      false -> panic(message)
    }
  }

  @doc = """
    Asserts that a boolean value is `false`. Panics on failure.
    """
  pub fn reject(value :: Bool) -> String {
    case value {
      false -> "."
      true -> panic("rejection failed: expected false, got true")
    }
  }

  @doc = """
    Asserts that a boolean value is `false` with a custom failure message.
    """
  pub fn reject(value :: Bool, message :: String) -> String {
    case value {
      false -> "."
      true -> panic(message)
    }
  }
}
