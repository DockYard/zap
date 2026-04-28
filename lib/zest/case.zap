@doc = """
  Test case DSL for the Zest test framework.

  Provides `describe`, `test`, `assert`, `reject`, `setup`, and
  `teardown` for writing structured test cases with test tracking.

  Setup runs fresh before EACH test that requests context.
  Teardown runs after each test. Assertions are non-fatal.

  The `describe` and `test` macros expand into function declarations
  so that each test becomes a named pub function (test_*) that is
  called at module level.

  ## Examples

      pub struct Test.MyTest {
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

pub struct Zest.Case {
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

    Scans the body for `setup` and `teardown` blocks, then
    transforms each `test` call into a pub function declaration
    with begin_test/end_test/print_result tracking calls injected.

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
    build_test_fns(_name, body, _setup_body, _teardown_body)
  }

  @doc = """
    Defines a test case without context.

    Expands into a pub function declaration named test_<slugified_name>
    with begin_test/end_test/print_result tracking calls wrapping the body.

    ## Examples

        test("true is true") {
          assert(true == true)
        }
    """

  pub macro test(_name :: Expr, body :: Expr) -> Expr {
    fn_name = __zap_intern_atom__("test_" <> __zap_slugify__(_name))
    quote {
      pub fn unquote(fn_name)() -> String {
        :zig.Zest.begin_test()
        unquote(body)
        :zig.Zest.end_test()
        :zig.Zest.print_result()
        "ok"
      }

      :zig.Zest.begin_test()
      unquote(fn_name)()
      :zig.Zest.end_test()
      :zig.Zest.print_result()
      "."
    }
  }

  @doc = """
    Wraps `begin_test` for explicit use.
    """

  pub fn begin_test() -> Atom {
    :zig.Zest.begin_test()
    :ok
  }

  @doc = """
    Wraps `end_test` for explicit use.
    """

  pub fn end_test() -> Atom {
    :zig.Zest.end_test()
    :ok
  }

  @doc = """
    Wraps `print_result` for explicit use.
    """

  pub fn print_result() -> Atom {
    :zig.Zest.print_result()
    :ok
  }

  @doc = """
    Asserts that a boolean value is `true`.

    Non-fatal: returns :fail on failure, does not stop execution.
    """

  pub fn assert(value :: Bool) -> String {
    if value {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion()
      "F"
    }
  }

  @doc = """
    Asserts that a boolean value is `false`.

    Non-fatal: returns "F" on failure, does not stop execution.
    """

  pub fn reject(value :: Bool) -> String {
    if not value {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion()
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
