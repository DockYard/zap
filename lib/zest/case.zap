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
    _stmts = elem(body, 2)
    _setup_matches = for _s <- _stmts, elem(_s, 0) == :setup { __zap_list_at__(elem(_s, 2), -1) }
    _teardown_matches = for _s <- _stmts, elem(_s, 0) == :teardown { __zap_list_at__(elem(_s, 2), -1) }
    _setup_body = __zap_list_at__(_setup_matches, 0)
    _teardown_body = __zap_list_at__(_teardown_matches, 0)
    _desc_slug = __zap_slugify__(_name)

    _per_test = for _t <- _stmts, elem(_t, 0) == :test {
      quote {
        pub fn unquote(__zap_intern_atom__("test_" <> _desc_slug <> "_" <> __zap_slugify__(__zap_list_at__(elem(_t, 2), 0))))() -> String {
          unquote(__zap_make_call__("__block__", __zap_list_concat__(__zap_list_concat__(__zap_list_concat__(if __zap_list_len__(elem(_t, 2)) == 3 and _setup_body != nil { [__zap_make_call__("=", [ctx, _setup_body])] } else { [] }, if elem(__zap_list_at__(elem(_t, 2), -1), 0) == :__block__ { elem(__zap_list_at__(elem(_t, 2), -1), 2) } else { [__zap_list_at__(elem(_t, 2), -1)] }), if _teardown_body != nil { [_teardown_body] } else { [] }), ["ok"])))
        }
        :zig.Zest.begin_test()
        unquote(__zap_intern_atom__("test_" <> _desc_slug <> "_" <> __zap_slugify__(__zap_list_at__(elem(_t, 2), 0))))()
        :zig.Zest.end_test()
        :zig.Zest.print_result()
        "."
      }
    }

    _passthrough = for _s <- _stmts, elem(_s, 0) != :test and elem(_s, 0) != :setup and elem(_s, 0) != :teardown { _s }

    _all = __zap_list_concat__(_per_test, _passthrough)

    quote { unquote_splicing(_all) }
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
        unquote(body)
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
