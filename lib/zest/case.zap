pub module Zest.Case {
  # Zest.Case provides assertions and the describe/test DSL for test modules.
  #
  # Usage:
  #   pub module Test.MyTest {
  #     use Zest.Case
  #
  #     describe "feature" {
  #       test "does something" {
  #         assert(1 + 1 == 2)
  #       }
  #     }
  #
  #     test "standalone test" {
  #       assert(true)
  #     }
  #   }

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  # Assertions

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

  # describe is a macro that takes a name and a block of tests.
  pub macro describe(name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
    }
  }

  # test is a macro that takes a name and a body block.
  pub macro test(name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
    }
  }
}
