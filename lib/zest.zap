pub module Zest {
  # Zest test framework.
  #
  # For test cases: use Zest.Case (provides assert/reject + describe/test DSL)
  # For test runner: use Zest.Runner (provides run_all)
  #
  # Legacy compatibility: `use Zest` still provides assert/reject directly.

  pub fn assert(value :: Bool) -> String {
    case value {
      true -> "."
      false -> panic("assertion failed")
    }
  }

  pub fn assert(value :: Bool, message :: String) -> String {
    case value {
      true -> "."
      false -> panic(message)
    }
  }

  pub fn reject(value :: Bool) -> String {
    case value {
      false -> "."
      true -> panic("rejection failed: expected false, got true")
    }
  }

  pub fn reject(value :: Bool, message :: String) -> String {
    case value {
      false -> "."
      true -> panic(message)
    }
  }
}
