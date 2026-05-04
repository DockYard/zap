@doc = """
  Test case DSL for the Zest test framework.

  Provides `describe`, `test`, `assert`, `reject`, `setup`, and
  `teardown` for writing structured test cases with test tracking.

  Setup runs fresh before EACH test that requests context.
  Teardown runs after each test. Assertions are non-fatal.

  The `describe` and `test` macros expand into function declarations
  so that each test becomes a named pub function (test_*). `use Zest.Case`
  installs a compile-time hook that generates `run/0` for the enclosing
  struct after all tests have been registered.

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
    Imports `Zest.Case` into the calling struct.
    """

  pub macro __using__(_opts :: Expr) -> Expr {
    struct_register_attribute(:before_compile)
    struct_put_attribute(:before_compile, "Zest.Case")
    struct_register_attribute(:zest_tests)

    quote {
      import Zest.Case
    }
  }

  @doc = """
    Generates the `run/0` function for a test struct.

    The hook reads the tests registered by `describe/2` and `test/2`,
    then emits a single public runner function that executes each test
    with Zest tracking around the call.
    """

  pub macro __before_compile__(env :: Expr) -> Decl {
    tests = struct_get_attribute(:zest_tests)
    test_list = if tests == nil {
      []
    } else {
      if list_length(tests) == 0 {
        [tests]
      } else {
        tests
      }
    }
    run_calls = for test <- test_list {
      quote {
        :zig.Zest.begin_test()
        unquote(make_call(".", [env, test]))()
        :zig.Zest.end_test()
        :zig.Zest.print_result()
      }
    }

    quote {
      @doc = "Runs all registered Zest tests in this struct."

      pub fn run() -> String {
        unquote_splicing(run_calls)
        "ok"
      }
    }
  }

  macro build_describe_test(desc_slug :: Expr, test_expr :: Expr, setup_body :: Expr, teardown_body :: Expr) -> Expr {
    test_name = intern_atom("test_" <> desc_slug <> "_" <> slugify(list_at(elem(test_expr, 2), 0)))
    struct_put_attribute(:zest_tests, test_name)

    quote {
      @doc = "Generated Zest test function."

      pub fn unquote(test_name)() -> String {
        unquote(make_call("__block__", list_concat(list_concat(list_concat(if list_length(elem(test_expr, 2)) == 3 and setup_body != nil { [make_call("=", [ctx, setup_body])] } else { [] }, if elem(list_at(elem(test_expr, 2), -1), 0) == :__block__ { elem(list_at(elem(test_expr, 2), -1), 2) } else { [list_at(elem(test_expr, 2), -1)] }), if teardown_body != nil { [teardown_body] } else { [] }), ["ok"])))
      }
    }
  }

  @doc = """
    Groups related tests under a descriptive label.

    Scans the body for `setup` and `teardown` blocks, then
    transforms each `test` call into a pub function declaration
    and registers the generated function for `run/0`.

    ## Examples

        describe("math") {
          setup() { 42 }

          test("addition", ctx) {
            assert(ctx == 42)
          }
        }
    """

  pub macro describe(name :: Expr, body :: Expr) -> Expr {
    stmts = elem(body, 2)
    setup_matches = for s <- stmts, elem(s, 0) == :setup { list_at(elem(s, 2), -1) }
    teardown_matches = for s <- stmts, elem(s, 0) == :teardown { list_at(elem(s, 2), -1) }
    setup_body = list_at(setup_matches, 0)
    teardown_body = list_at(teardown_matches, 0)
    desc_slug = slugify(name)

    per_test = for t <- stmts, elem(t, 0) == :test {
      build_describe_test(desc_slug, t, setup_body, teardown_body)
    }

    passthrough = for s <- stmts, elem(s, 0) != :test and elem(s, 0) != :setup and elem(s, 0) != :teardown { s }

    all_stmts = list_concat(per_test, passthrough)

    quote { unquote_splicing(all_stmts) }
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

  pub macro test(name :: Expr, body :: Expr) -> Expr {
    fn_name = intern_atom("test_" <> slugify(name))
    struct_put_attribute(:zest_tests, fn_name)

    quote {
      @doc = "Generated Zest test function."

      pub fn unquote(fn_name)() -> String {
        unquote(body)
        "ok"
      }
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
