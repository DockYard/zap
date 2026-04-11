pub module Zest.Case {
  @moduledoc = """
    Test case DSL for the Zest test framework.

    Provides `describe`, `test`, `assert`, `reject`, `setup`, and
    `teardown` for writing structured test cases with ExUnit-style
    test tracking. Use `use Zest.Case` at the top of your test module
    to import these.

    Each test calls `begin_test` before running and `end_test` after.
    Assertions track pass and fail counts via `:zig.TestTracker`.
    On success a dot is returned; on failure an F is returned and the
    test is marked as failed, but execution continues (non-fatal).

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

    Calls `begin_test` before running the body and `end_test`
    after. If any assertion in the body fails, the test is
    marked as failed but execution continues to the next test
    (non-fatal). Returns "." when complete.

    ## Examples

        test("true is true") {
          assert(true == true)
        }
    """

  pub macro test(_name :: Expr, body :: Expr) -> Expr {
    quote {
      :zig.TestTracker.begin_test()
      unquote(body)
      :zig.TestTracker.end_test()
      "."
    }
  }

  @doc = """
    Asserts that a boolean value is `true`.

    On success, increments the assertion pass counter and
    returns ".". On failure, increments the assertion fail
    counter, marks the current test as failed, and returns
    "F". Execution continues (non-fatal).

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
      "F"
    }
  }

  @doc = """
    Asserts that a boolean value is `false`.

    On success, increments the assertion pass counter and
    returns ".". On failure, increments the assertion fail
    counter, marks the current test as failed, and returns
    "F". Execution continues (non-fatal).

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
      "F"
    }
  }

  @doc = """
    Runs setup code before tests in the current scope.

    The body is inlined directly and executes where the
    `setup` call appears. Use inside a `describe` block
    to run initialization before test code.

    ## Examples

        describe("with setup") {
          setup {
            IO.puts("initializing")
          }
          test("it works") {
            assert(true)
          }
        }
    """

  pub macro setup(body :: Expr) -> Expr {
    quote { unquote(body) }
  }

  @doc = """
    Runs teardown code after tests in the current scope.

    The body is inlined directly and executes where the
    `teardown` call appears. Use inside a `describe` block
    to run cleanup after test code.

    ## Examples

        describe("with teardown") {
          test("it works") {
            assert(true)
          }
          teardown {
            IO.puts("cleaning up")
          }
        }
    """

  pub macro teardown(body :: Expr) -> Expr {
    quote { unquote(body) }
  }
}
