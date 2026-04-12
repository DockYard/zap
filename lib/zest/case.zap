pub module Zest.Case {
  @moduledoc = """
    Test case DSL for the Zest test framework.

    Provides `describe`, `test`, `assert`, `reject`, `setup`, and
    `teardown` for writing structured test cases with test tracking.

    Setup runs fresh before EACH test that requests context.
    Teardown runs after each test. Assertions are non-fatal.

    ## Examples

        pub module Test.MyTest {
          use Zest.Case

          describe("my feature") {
            setup() {
              42
            }

            test("uses context", ctx) {
              assert(ctx == 42)
            }

            test("no context needed") {
              assert(true)
            }

            teardown() {
              IO.puts("cleanup")
            }
          }
        }
    """

  @doc = """
    Imports `Zest.Case` into the calling module.
    """

  pub macro __using__(_opts :: Expr) -> Expr {
    quote {
      import Zest.Case
    }
  }

  @doc = """
    Groups related tests under a descriptive label.

    Scans the body for `setup` and `teardown` blocks. The setup
    body is injected into each `test/3` call so it re-runs fresh
    before every test. Teardown is injected after each test body.

    ## Examples

        describe("math") {
          setup() { 42 }

          test("addition", ctx) {
            assert(ctx == 42)
          }
        }
    """

  pub macro describe(_name :: Expr, body :: Expr) -> Expr {
    _setup_body = find_setup(body)
    _teardown_body = find_teardown(body)
    inject_setup(body, _setup_body, _teardown_body)
  }

  @doc = """
    Defines a test case without context.

    Calls `begin_test` before running the body and `end_test`
    after. If any assertion fails, the test is marked as failed
    but execution continues (non-fatal).

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

    Non-fatal: returns "F" on failure, does not stop execution.
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

    Non-fatal: returns "F" on failure, does not stop execution.
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
    Declares setup code that runs before each test with context.

    Place inside a `describe` block. The return value is bound
    to `ctx` in each `test/3` call. Runs fresh for every test.

    ## Examples

        setup() {
          connect_db()
        }
    """

  pub macro setup(body :: Expr) -> Expr {
    quote { unquote(body) }
  }

  @doc = """
    Declares teardown code that runs after each test.

    Place inside a `describe` block. Runs after every test body,
    even if assertions fail (non-fatal assertions).

    ## Examples

        teardown() {
          disconnect_db()
        }
    """

  pub macro teardown(body :: Expr) -> Expr {
    quote { unquote(body) }
  }
}
