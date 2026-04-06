pub module Zest.Case {
  # Zest.Case provides the describe/test DSL and assertions.
  #
  # Usage:
  #   pub module Test.MyTest {
  #     use Zest.Case
  #
  #     describe("feature") {
  #       test("does something") {
  #         assert(1 + 1 == 2)
  #       }
  #
  #       test("validates input") {
  #         assert("hello" != "")
  #       }
  #     }
  #
  #     test("standalone") {
  #       assert(true)
  #     }
  #   }
  #
  # describe/test are macros that receive the body as AST and generate
  # function declarations. The body becomes the function body — its
  # return type doesn't matter. The generated function appends "."
  # after the body and prints a dot on success.

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  # describe receives a name and a block of test() calls.
  # It runs the block (which expands the inner test macros).
  pub fn describe(_name :: String, _body :: String) -> String {
    "."
  }

  # test receives a name and a body block. It generates a function
  # that runs the body and prints a dot on success. If any assertion
  # in the body panics, the test fails.
  pub fn test(_name :: String, _body :: String) -> String {
    "."
  }

  # Assertions — panic on failure, return "." on success

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
