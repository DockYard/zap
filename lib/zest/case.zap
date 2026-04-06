pub module Zest.Case {
  # Zest.Case provides the describe/test DSL and assertions.
  #
  # Usage:
  #   pub module Test.MyTest {
  #     use Zest.Case
  #
  #     pub fn run() -> String {
  #       describe("feature") {
  #         test("does something") {
  #           assert(1 + 1 == 2)
  #         }
  #
  #         test("validates input") {
  #           assert("hello" != "")
  #         }
  #       }
  #
  #       "MyTest: passed"
  #     }
  #   }

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  # describe runs a block of tests, printing the describe name in verbose mode.
  # The block contains test() calls which execute and print dots.
  pub fn describe(_name :: String, _body :: String) -> String {
    "."
  }

  # test runs a block of assertions. The block is evaluated — if all assertions
  # pass, the block returns ".". If any assert/reject fails, it panics.
  # The name and result are used for output.
  pub fn test(_name :: String, _body :: String) -> String {
    IO.print_str(".")
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
