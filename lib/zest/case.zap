pub module Zest.Case {
  # Zest.Case provides the describe/test DSL for test modules.
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
  #
  # The __using__ macro injects assert/reject helpers
  # and the describe/test macros into the calling module.

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest
    }
  }

  # describe is a macro that takes a name and a block of tests.
  # It generates functions prefixed with the describe name.
  #
  # describe "math" {
  #   test "addition" { assert(1 + 1 == 2) }
  # }
  # →
  # fn __test__math__addition() -> String { assert(1 + 1 == 2); "." }
  pub macro describe(name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
    }
  }

  # test is a macro that takes a name and a body block.
  # It generates a private function that runs the assertions.
  #
  # test "works" { assert(true) }
  # →
  # fn __test__works() -> String { assert(true); "." }
  pub macro test(name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
    }
  }
}
