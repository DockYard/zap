pub module Zest.Case {
  @moduledoc = """
    Test case DSL for the Zest test framework.

    Provides `describe`, `test`, `assert`, and `reject` for writing
    structured test cases. Use `use Zest.Case` at the top of your
    test module to import these.

    ## Examples

        pub module Test.MyTest {
          use Zest.Case

          pub fn run() -> String {
            describe("my feature") {
              test("it works") {
                assert(1 + 1 == 2)
              }
            }
            "done"
          }
        }
    """

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  @doc = """
    Groups related tests under a descriptive label.

    The label is for human readability only — it does not
    affect test execution.

    ## Examples

        describe("math") {
          test("addition") {
            assert(1 + 1 == 2)
          }
        }
    """

  pub macro describe(name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
    }
  }

  @doc = """
    Defines a single test case.

    The test body is executed and a green dot is printed to
    stdout on completion. If an assertion fails inside the
    body, the process panics with the failure message.

    ## Examples

        test("true is true") {
          assert(true == true)
        }
    """

  pub macro test(name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
      IO.print_str("\x1b[1;32m.\x1b[0m")
    }
  }

  @doc = """
    Asserts that a boolean value is `true`.

    Panics with "assertion failed" if the value is `false`.

    ## Examples

        assert(1 + 1 == 2)    # passes
        assert(true)           # passes
        assert(false)          # panics
    """

  pub fn assert(value :: Bool) -> String {
    case value {
      true -> "."
      false -> panic("assertion failed")
    }
  }

  @doc = """
    Asserts that a boolean value is `false`.

    Panics with "rejection failed" if the value is `true`.

    ## Examples

        reject(1 > 100)  # passes
        reject(false)     # passes
        reject(true)      # panics
    """

  pub fn reject(value :: Bool) -> String {
    case value {
      false -> "."
      true -> panic("rejection failed")
    }
  }
}
