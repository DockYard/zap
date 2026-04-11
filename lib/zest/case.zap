pub module Zest.Case {
  @moduledoc = """
    Test case DSL for the Zest test framework.

    Provides `describe`, `test`, `assert`, and `reject` for writing
    structured test cases with ExUnit-style test tracking. Use
    `use Zest.Case` at the top of your test module to import these.

    Each test increments a global test counter before running.
    Assertions track pass and fail counts via `:zig.TestTracker`.
    On success a green dot is printed; on failure a red F is printed
    and the process panics.

    ## Examples

        pub module Test.MyTest {
          use Zest.Case

          pub fn run() -> String {
            describe("my feature") {
              test("it works") {
                assert(1 + 1 == 2)
              }
            }
          }
        }
    """

  @doc = """
    Imports `Zest.Case` into the calling module.

    Called automatically when you write `use Zest.Case`.
    """

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  @doc = """
    Groups related tests under a descriptive label.

    The label is for human readability only and does not
    affect test execution. The body is executed directly.

    ## Examples

        describe("math") {
          test("addition") {
            assert(1 + 1 == 2)
          }
        }
    """

  pub macro describe(_name :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(body)
    }
  }

  @doc = """
    Defines a single test case with tracking.

    Increments the global test counter before running the body.
    If all assertions in the body pass, prints a green dot to
    stdout. If any assertion fails, the assertion itself prints
    a red F and panics before the dot is reached.

    ## Examples

        test("true is true") {
          assert(true == true)
        }
    """

  pub macro test(_name :: Expr, body :: Expr) -> Expr {
    quote {
      :zig.TestTracker.increment_tests()
      unquote(body)
      :zig.TestTracker.print_dot()
      "."
    }
  }

  @doc = """
    Asserts that a boolean value is `true`.

    On success, increments the assertion pass counter.
    On failure, increments the assertion fail counter
    and the test failure counter, prints a red F,
    then panics with "assertion failed".

    ## Examples

        assert(1 + 1 == 2)
        assert(true)
    """

  pub fn assert(value :: Bool) -> String {
    if value {
      :zig.TestTracker.pass_assertion()
      "."
    } else {
      :zig.TestTracker.fail_assertion()
      :zig.TestTracker.increment_test_failures()
      :zig.TestTracker.print_fail()
      panic("assertion failed")
    }
  }

  @doc = """
    Asserts that a boolean value is `false`.

    On success, increments the assertion pass counter.
    On failure, increments the assertion fail counter
    and the test failure counter, prints a red F,
    then panics with "rejection failed".

    ## Examples

        reject(1 > 100)
        reject(false)
    """

  pub fn reject(value :: Bool) -> String {
    if not value {
      :zig.TestTracker.pass_assertion()
      "."
    } else {
      :zig.TestTracker.fail_assertion()
      :zig.TestTracker.increment_test_failures()
      :zig.TestTracker.print_fail()
      panic("rejection failed")
    }
  }
}
