pub module Zest.Case {
  # Zest.Case provides assertions and the test DSL.
  #
  # Usage:
  #   pub module Test.MyTest {
  #     use Zest.Case
  #
  #     pub fn run() -> String {
  #       describe("feature")
  #
  #       test("does something",
  #         assert(1 + 1 == 2)
  #       )
  #
  #       test("validates input",
  #         assert("hello" != "")
  #       )
  #
  #       end_describe()
  #       Zest.summary()
  #     }
  #   }

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  # Test lifecycle

  pub fn describe(name :: String) -> String {
    Zest.begin_describe(name)
    "."
  }

  pub fn end_describe() -> String {
    Zest.end_describe()
    "."
  }

  pub fn test(name :: String, result :: String) -> String {
    Zest.run_test(name, result == ".")
    "."
  }

  pub fn summary() -> String {
    Zest.summary()
  }

  pub fn reset() -> String {
    Zest.reset()
    "."
  }

  # Assertions — return "." on success, panic on failure

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
