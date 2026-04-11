pub module Zest.Case {
  @moduledoc = """
    Test case DSL for the Zest test framework.

    Provides `describe`, `test`, `assert`, `reject`, `setup`, and
    `teardown` for writing structured test cases with test tracking.
    Use `use Zest.Case` at the top of your test module to import these.

    Each test calls `begin_test` before running and `end_test` after.
    Assertions track pass and fail counts via `:zig.TestTracker`.
    On success a dot is returned; on failure an F is returned and the
    test is marked as failed, but execution continues (non-fatal).

    ## Setup and Context

    The `setup` macro runs before tests and its return value becomes
    the test context. Tests can receive the context as a second
    parameter:

        describe("with context") {
          setup() {
            42
          }

          test("uses context", ctx) {
            assert(ctx == 42)
          }

          test("no context needed") {
            assert(true)
          }
        }

    ## Examples

        pub module Test.MyTest {
          use Zest.Case

          describe("my feature") {
            test("it works") {
              assert(1 + 1 == 2)
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
    Defines a single test case without context.

    Calls `begin_test` before running the body and `end_test`
    after. If any assertion in the body fails, the test is
    marked as failed but execution continues (non-fatal).

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
    Runs setup code and provides context to tests.

    The return value of the body becomes the test context,
    accessible via the second argument of `test/3`. The
    context is stored in a scoped variable that tests can
    bind to.

    ## Examples

        describe("with setup") {
          setup() {
            conn = connect_db()
            conn
          }

          test("uses connection", ctx) {
            assert(query(ctx) == :ok)
          }
        }
    """

  pub macro setup(body :: Expr) -> Expr {
    quote {
      __test_context__ = unquote(body)
    }
  }

  @doc = """
    Runs teardown code after tests in the current scope.

    The body is inlined directly and executes where the
    `teardown` call appears. Since assertions are non-fatal,
    teardown code always runs even when tests fail.

    ## Examples

        describe("with teardown") {
          test("it works") {
            assert(true)
          }

          teardown() {
            disconnect_db()
          }
        }
    """

  pub macro teardown(body :: Expr) -> Expr {
    quote { unquote(body) }
  }
}
