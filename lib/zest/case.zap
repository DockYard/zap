@doc = """
  Test case DSL for the Zest test framework.

  Provides `test`, `case`, `assert`, `reject`, `setup`, and `teardown`
  for writing structured test cases with test tracking.

  `test("subject") { ... }` is a grouping macro. Each nested
  `case("behavior") { ... }` is an executable leaf. Setup and teardown
  blocks inside a `test` group run once per case.

  `describe("subject") { test("behavior") { ... } }` remains supported
  as a compatibility alias during the DSL migration. It lowers to the
  same internal case records as `test/case`.

  ## Examples

      pub struct Test.MyTest {
        use Zest.Case

        test("my feature") {
          setup() {
            42
          }

          case("uses context", ctx) {
            assert(ctx == 42)
          }

          case("no context needed") {
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

    The hook reads accumulated case records registered by `test/case`
    and compatibility `describe/test`, then emits a single public
    runner function that executes each case with Zest tracking around
    the generated function call.
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
    test_count = list_length(test_list)
    run_calls = for test_record <- test_list { build_run_call(env, test_record) }
    selected_run_calls = for test_record <- test_list { build_selected_run_call(env, test_record) }

    quote {
      @doc = """
        Runs all registered Zest cases in this struct.
        """

      pub fn run() -> String {
        unquote_splicing(run_calls)
        "ok"
      }

      @doc = """
        Returns the number of Zest cases generated for this struct.
        """

      pub fn zest_case_count() -> i64 {
        unquote(test_count)
      }

      @doc = """
        Scans this struct's generated Zest cases and runs the selected case.
        """

      pub fn zest_run_selected_case(selected_index :: i64) -> String {
        :zig.Zest.begin_selected_case(selected_index)
        unquote_splicing(selected_run_calls)
        :zig.Zest.end_selected_case()
        "ok"
      }
    }
  }

  macro build_run_call(env :: Expr, test_record :: Expr) -> Expr {
    generated_function_name = elem(test_record, 0)
    test_label = elem(test_record, 1)
    case_label = elem(test_record, 2)
    test_display_name = display_name(alias_name(env), test_label, case_label)

    quote {
      :zig.Zest.begin_named_test(unquote(test_display_name))
      unquote(make_call(".", [env, generated_function_name]))()
      :zig.Zest.end_test()
      :zig.Zest.print_result()
    }
  }

  macro display_name(struct_name :: Expr, test_label :: Expr, case_label :: Expr) -> Expr {
    if case_label == "" {
      struct_name <> " - " <> test_label
    } else {
      struct_name <> " - " <> test_label <> " - " <> case_label
    }
  }

  macro alias_name(struct_alias :: Expr) -> Expr {
    alias_name_parts(elem(struct_alias, 2), 0)
  }

  macro alias_name_parts(parts :: Expr, index :: Expr) -> Expr {
    if index >= list_length(parts) {
      ""
    } else {
      name = atom_name(list_at(parts, index))
      rest = alias_name_parts(parts, index + 1)

      if rest == "" {
        name
      } else {
        name <> "." <> rest
      }
    }
  }

  macro build_selected_run_call(env :: Expr, test_record :: Expr) -> Expr {
    run_call = build_run_call(env, test_record)

    quote {
      if :zig.Zest.should_run_selected_case() {
        unquote(run_call)
      }
    }
  }

  macro build_case_decl(test_name :: Expr, test_slug :: Expr, setup_expr :: Expr, teardown_expr :: Expr, case_expr :: Expr) -> Expr {
    case_args = elem(case_expr, 2)
    case_name = list_at(case_args, 0)
    case_body = list_at(case_args, -1)
    generated_function_name = intern_atom("test_" <> test_slug <> "_" <> slugify(case_name))
    test_label = test_name <> ""
    case_label = case_name <> ""
    struct_put_attribute(:zest_tests, tuple(generated_function_name, test_label, case_label))

    context_setup = if list_length(case_args) == 3 and setup_expr != nil {
      [make_call("=", [list_at(case_args, 1), setup_expr])]
    } else {
      []
    }
    case_body_statements = if elem(case_body, 0) == :__block__ { elem(case_body, 2) } else { [case_body] }
    teardown_statements = if teardown_expr != nil { [teardown_expr] } else { [] }
    generated_body = make_call("__block__", list_concat(list_concat(list_concat(context_setup, case_body_statements), teardown_statements), ["ok"]))

    quote {
      @doc = """
        Generated Zest case function.
        """

      pub fn unquote(generated_function_name)() -> String {
        unquote(generated_body)
      }
    }
  }

  @doc = """
    Defines a test group.

    Nested `case/2` or `case/3` calls become executable test cases.
    Setup and teardown blocks in the group run once per case.

    If no nested case is present, `test/2` falls back to the legacy
    leaf-test behavior for migration compatibility.

    ## Examples

        test("math") {
          setup() { 40 }

          case("addition", ctx) {
            assert(ctx + 2 == 42)
          }
        }
    """

  pub macro test(name :: Expr, body :: Expr) -> Expr {
    stmts = if elem(body, 0) == :__block__ { elem(body, 2) } else { [body] }
    case_stmts = for stmt <- stmts, elem(stmt, 0) == :case { stmt }

    if list_length(case_stmts) == 0 {
      generated_function_name = intern_atom("test_" <> slugify(name))
      test_label = name <> ""
      struct_put_attribute(:zest_tests, tuple(generated_function_name, test_label, ""))

      quote {
        @doc = """
          Generated Zest compatibility test function.
          """

        pub fn unquote(generated_function_name)() -> String {
          unquote(body)
          "ok"
        }
      }
    } else {
      setup_matches = for stmt <- stmts, elem(stmt, 0) == :setup { list_at(elem(stmt, 2), -1) }
      teardown_matches = for stmt <- stmts, elem(stmt, 0) == :teardown { list_at(elem(stmt, 2), -1) }
      setup_expr = list_at(setup_matches, 0)
      teardown_expr = list_at(teardown_matches, 0)
      test_slug = slugify(name)

      per_case = for case_expr <- case_stmts { build_case_decl(name, test_slug, setup_expr, teardown_expr, case_expr) }

      passthrough = for stmt <- stmts, elem(stmt, 0) != :case and elem(stmt, 0) != :setup and elem(stmt, 0) != :teardown { stmt }
      all_stmts = list_concat(per_case, passthrough)

      quote { unquote_splicing(all_stmts) }
    }
  }

  @doc = """
    Declares an executable case inside a `test` group.

    `case("label") { ... }` runs without setup context. Use
    `case("label", ctx) { ... }` to bind the value returned by the
    group's setup block to a context variable.
    """

  pub macro case(_name :: Expr, body :: Expr) -> Expr {
    quote { unquote(body) }
  }

  @doc = """
    Declares an executable case with setup context inside a `test` group.

    This macro exists so `case("label", ctx) { ... }` is a first-class
    Zest form even before the enclosing `test` group consumes it.
    """

  pub macro case(_name :: Expr, _context :: Expr, body :: Expr) -> Expr {
    quote { unquote(body) }
  }

  @doc = """
    Compatibility alias for the pre-migration Zest DSL.

    `describe("subject") { test("behavior") { ... } }` is still
    accepted and lowers to the same case records as the primary
    `test("subject") { case("behavior") { ... } }` DSL.
    """

  pub macro describe(name :: Expr, body :: Expr) -> Expr {
    stmts = if elem(body, 0) == :__block__ { elem(body, 2) } else { [body] }
    setup_matches = for stmt <- stmts, elem(stmt, 0) == :setup { list_at(elem(stmt, 2), -1) }
    teardown_matches = for stmt <- stmts, elem(stmt, 0) == :teardown { list_at(elem(stmt, 2), -1) }
    setup_expr = list_at(setup_matches, 0)
    teardown_expr = list_at(teardown_matches, 0)
    test_slug = slugify(name)

    test_stmts = for stmt <- stmts, elem(stmt, 0) == :test { stmt }
    per_case = for test_expr <- test_stmts { build_case_decl(name, test_slug, setup_expr, teardown_expr, test_expr) }

    passthrough = for stmt <- stmts, elem(stmt, 0) != :test and elem(stmt, 0) != :setup and elem(stmt, 0) != :teardown { stmt }
    all_stmts = list_concat(per_case, passthrough)

    quote { unquote_splicing(all_stmts) }
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
    Asserts that an expression evaluates to `true`.

    The expression is received as AST so Zest can report source code,
    source locations, evaluated values, and comparison operands
    without evaluating operands more than once.
    """

  pub macro assert(expression :: Expr) -> Expr {
    operator_name = atom_name(elem(expression, 0))
    args = elem(expression, 2)

    if comparison_operator?(operator_name) and list_length(args) == 2 {
      left_expression = list_at(args, 0)
      right_expression = list_at(args, 1)
      code = source_text(expression)
      left_code = source_text(left_expression)
      right_code = source_text(right_expression)
      location = source_location(expression)

      if operator_name == "==" {
        quote {
          zest_assertion_left_value = unquote(left_expression)
          zest_assertion_right_value = unquote(right_expression)
          Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value == zest_assertion_right_value, "", unquote(location))
        }
      } else {
        if operator_name == "!=" {
          quote {
            zest_assertion_left_value = unquote(left_expression)
            zest_assertion_right_value = unquote(right_expression)
            Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value != zest_assertion_right_value, "", unquote(location))
          }
        } else {
          if operator_name == "<" {
            quote {
              zest_assertion_left_value = unquote(left_expression)
              zest_assertion_right_value = unquote(right_expression)
              Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value < zest_assertion_right_value, "", unquote(location))
            }
          } else {
            if operator_name == ">" {
              quote {
                zest_assertion_left_value = unquote(left_expression)
                zest_assertion_right_value = unquote(right_expression)
                Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value > zest_assertion_right_value, "", unquote(location))
              }
            } else {
              if operator_name == "<=" {
                quote {
                  zest_assertion_left_value = unquote(left_expression)
                  zest_assertion_right_value = unquote(right_expression)
                  Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value <= zest_assertion_right_value, "", unquote(location))
                }
              } else {
                quote {
                  zest_assertion_left_value = unquote(left_expression)
                  zest_assertion_right_value = unquote(right_expression)
                  Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value >= zest_assertion_right_value, "", unquote(location))
                }
              }
            }
          }
        }
      }
    } else {
      code = source_text(expression)
      location = source_location(expression)

      quote {
        zest_assertion_value = unquote(expression)
        Zest.Assertion.truthy_result("assert", unquote(code), Kernel.to_string(zest_assertion_value), zest_assertion_value, "", unquote(location))
      }
    }
  }

  @doc = """
    Asserts that an expression evaluates to `true` with a custom message.

    Custom messages supplement the structural assertion diagnostics.
    """

  pub macro assert(expression :: Expr, message :: Expr) -> Expr {
    operator_name = atom_name(elem(expression, 0))
    args = elem(expression, 2)

    if comparison_operator?(operator_name) and list_length(args) == 2 {
      left_expression = list_at(args, 0)
      right_expression = list_at(args, 1)
      code = source_text(expression)
      left_code = source_text(left_expression)
      right_code = source_text(right_expression)
      location = source_location(expression)

      if operator_name == "==" {
        quote {
          zest_assertion_left_value = unquote(left_expression)
          zest_assertion_right_value = unquote(right_expression)
          Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value == zest_assertion_right_value, unquote(message), unquote(location))
        }
      } else {
        if operator_name == "!=" {
          quote {
            zest_assertion_left_value = unquote(left_expression)
            zest_assertion_right_value = unquote(right_expression)
            Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value != zest_assertion_right_value, unquote(message), unquote(location))
          }
        } else {
          if operator_name == "<" {
            quote {
              zest_assertion_left_value = unquote(left_expression)
              zest_assertion_right_value = unquote(right_expression)
              Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value < zest_assertion_right_value, unquote(message), unquote(location))
            }
          } else {
            if operator_name == ">" {
              quote {
                zest_assertion_left_value = unquote(left_expression)
                zest_assertion_right_value = unquote(right_expression)
                Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value > zest_assertion_right_value, unquote(message), unquote(location))
              }
            } else {
              if operator_name == "<=" {
                quote {
                  zest_assertion_left_value = unquote(left_expression)
                  zest_assertion_right_value = unquote(right_expression)
                  Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value <= zest_assertion_right_value, unquote(message), unquote(location))
                }
              } else {
                quote {
                  zest_assertion_left_value = unquote(left_expression)
                  zest_assertion_right_value = unquote(right_expression)
                  Zest.Assertion.comparison_result("assert", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value >= zest_assertion_right_value, unquote(message), unquote(location))
                }
              }
            }
          }
        }
      }
    } else {
      code = source_text(expression)
      location = source_location(expression)

      quote {
        zest_assertion_value = unquote(expression)
        Zest.Assertion.truthy_result("assert", unquote(code), Kernel.to_string(zest_assertion_value), zest_assertion_value, unquote(message), unquote(location))
      }
    }
  }

  @doc = """
    Asserts that an expression evaluates to `false`.

    The expression is received as AST so Zest can report source code,
    source locations, evaluated values, and comparison operands
    without evaluating operands more than once.
    """

  pub macro reject(expression :: Expr) -> Expr {
    operator_name = atom_name(elem(expression, 0))
    args = elem(expression, 2)

    if comparison_operator?(operator_name) and list_length(args) == 2 {
      left_expression = list_at(args, 0)
      right_expression = list_at(args, 1)
      code = source_text(expression)
      left_code = source_text(left_expression)
      right_code = source_text(right_expression)
      location = source_location(expression)

      if operator_name == "==" {
        quote {
          zest_assertion_left_value = unquote(left_expression)
          zest_assertion_right_value = unquote(right_expression)
          Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value == zest_assertion_right_value, "", unquote(location))
        }
      } else {
        if operator_name == "!=" {
          quote {
            zest_assertion_left_value = unquote(left_expression)
            zest_assertion_right_value = unquote(right_expression)
            Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value != zest_assertion_right_value, "", unquote(location))
          }
        } else {
          if operator_name == "<" {
            quote {
              zest_assertion_left_value = unquote(left_expression)
              zest_assertion_right_value = unquote(right_expression)
              Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value < zest_assertion_right_value, "", unquote(location))
            }
          } else {
            if operator_name == ">" {
              quote {
                zest_assertion_left_value = unquote(left_expression)
                zest_assertion_right_value = unquote(right_expression)
                Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value > zest_assertion_right_value, "", unquote(location))
              }
            } else {
              if operator_name == "<=" {
                quote {
                  zest_assertion_left_value = unquote(left_expression)
                  zest_assertion_right_value = unquote(right_expression)
                  Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value <= zest_assertion_right_value, "", unquote(location))
                }
              } else {
                quote {
                  zest_assertion_left_value = unquote(left_expression)
                  zest_assertion_right_value = unquote(right_expression)
                  Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value >= zest_assertion_right_value, "", unquote(location))
                }
              }
            }
          }
        }
      }
    } else {
      code = source_text(expression)
      location = source_location(expression)

      quote {
        zest_assertion_value = unquote(expression)
        Zest.Assertion.truthy_result("reject", unquote(code), Kernel.to_string(zest_assertion_value), zest_assertion_value, "", unquote(location))
      }
    }
  }

  @doc = """
    Asserts that an expression evaluates to `false` with a custom message.

    Custom messages supplement the structural rejection diagnostics.
    """

  pub macro reject(expression :: Expr, message :: Expr) -> Expr {
    operator_name = atom_name(elem(expression, 0))
    args = elem(expression, 2)

    if comparison_operator?(operator_name) and list_length(args) == 2 {
      left_expression = list_at(args, 0)
      right_expression = list_at(args, 1)
      code = source_text(expression)
      left_code = source_text(left_expression)
      right_code = source_text(right_expression)
      location = source_location(expression)

      if operator_name == "==" {
        quote {
          zest_assertion_left_value = unquote(left_expression)
          zest_assertion_right_value = unquote(right_expression)
          Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value == zest_assertion_right_value, unquote(message), unquote(location))
        }
      } else {
        if operator_name == "!=" {
          quote {
            zest_assertion_left_value = unquote(left_expression)
            zest_assertion_right_value = unquote(right_expression)
            Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value != zest_assertion_right_value, unquote(message), unquote(location))
          }
        } else {
          if operator_name == "<" {
            quote {
              zest_assertion_left_value = unquote(left_expression)
              zest_assertion_right_value = unquote(right_expression)
              Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value < zest_assertion_right_value, unquote(message), unquote(location))
            }
          } else {
            if operator_name == ">" {
              quote {
                zest_assertion_left_value = unquote(left_expression)
                zest_assertion_right_value = unquote(right_expression)
                Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value > zest_assertion_right_value, unquote(message), unquote(location))
              }
            } else {
              if operator_name == "<=" {
                quote {
                  zest_assertion_left_value = unquote(left_expression)
                  zest_assertion_right_value = unquote(right_expression)
                  Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value <= zest_assertion_right_value, unquote(message), unquote(location))
                }
              } else {
                quote {
                  zest_assertion_left_value = unquote(left_expression)
                  zest_assertion_right_value = unquote(right_expression)
                  Zest.Assertion.comparison_result("reject", unquote(operator_name), unquote(code), unquote(left_code), Kernel.to_string(zest_assertion_left_value), unquote(right_code), Kernel.to_string(zest_assertion_right_value), zest_assertion_left_value >= zest_assertion_right_value, unquote(message), unquote(location))
                }
              }
            }
          }
        }
      }
    } else {
      code = source_text(expression)
      location = source_location(expression)

      quote {
        zest_assertion_value = unquote(expression)
        Zest.Assertion.truthy_result("reject", unquote(code), Kernel.to_string(zest_assertion_value), zest_assertion_value, unquote(message), unquote(location))
      }
    }
  }

  @doc = """
    Asserts that a block leaks no memory.

    `assert_no_leaks { <block> }` runs `<block>` and asserts the net number of
    live (un-freed) heap allocations attributable to it is zero. It samples the
    active memory manager's live-allocation count immediately before and after
    the block; a positive delta means the block allocated and abandoned memory,
    which fails the assertion with the leaked allocation count + bytes as the
    failure detail (alongside the deinit-time attributed report).

    Requires the test target to select `Memory.Tracking` (the manager that
    exposes the live-allocation checkpoint). Under any other manager the live
    set is not observable, so the assertion is a documented no-op that passes.

    ## Examples

        case("builder frees its scratch buffer") {
          assert_no_leaks {
            result = Builder.run(input)
            assert(result == expected)
          }
        }
    """

  pub macro assert_no_leaks(block :: Expr) -> Expr {
    code = source_text(block)
    location = source_location(block)

    quote {
      zest_leak_tracking_active = :zig.Memory.leak_tracking_active()
      zest_leak_before_count = :zig.Memory.live_allocation_count()
      zest_leak_before_bytes = :zig.Memory.live_allocation_bytes()
      unquote(block)
      zest_leak_after_count = :zig.Memory.live_allocation_count()
      zest_leak_after_bytes = :zig.Memory.live_allocation_bytes()
      Zest.Assertion.no_leaks_result(zest_leak_tracking_active, zest_leak_before_count, zest_leak_after_count, zest_leak_before_bytes, zest_leak_after_bytes, unquote(code), unquote(location))
    }
  }

  @doc = """
    Asserts that a block creates no reference cycle.

    `assert_no_cycles { <block> }` runs `<block>`, then drives the runtime
    Bacon–Rajan trial-deletion cycle detector over the allocations the block
    left live and asserts none are held alive only by a reference cycle. A
    detected cycle fails the assertion with the participating-object count +
    bytes; the full `domain=cycle` retain-path report is rendered alongside.

    Requires `Memory.Tracking` with cycle checking enabled (the runtime cycle
    scan). Under any other configuration the assertion is a documented no-op
    that passes.

    Phase-5 caveat: a reference cycle is not constructible from today's fully
    immutable Zap surface (no field mutation, no `Ref`/`weak`), so on real Zap
    code this assertion always passes. It is wired to the detector signal now
    and the detect-and-fail path is unit-verified at the runtime level, ready to
    catch cycles the moment Phase 5 lands mutation.
    """

  pub macro assert_no_cycles(block :: Expr) -> Expr {
    code = source_text(block)
    location = source_location(block)

    quote {
      zest_cycle_check_active = :zig.Memory.cycle_check_active()
      unquote(block)
      zest_cycle_object_count = :zig.Memory.scan_live_cycles()
      zest_cycle_bytes = :zig.Memory.last_cycle_scan_bytes()
      Zest.Assertion.no_cycles_result(zest_cycle_check_active, zest_cycle_object_count, zest_cycle_bytes, unquote(code), unquote(location))
    }
  }

  macro comparison_operator?(operator_name :: Expr) -> Expr {
    if operator_name == "==" {
      true
    } else {
      if operator_name == "!=" {
        true
      } else {
        if operator_name == "<" {
          true
        } else {
          if operator_name == ">" {
            true
          } else {
            if operator_name == "<=" {
              true
            } else {
              operator_name == ">="
            }
          }
        }
      }
    }
  }

  @doc = """
    Declares setup code that runs before each case in a `test` group.

    The return value can be bound by cases that declare a context
    variable with `case("label", ctx) { ... }`.
    """

  pub macro setup(body :: Expr) -> Expr {
    quote { unquote(body) }
  }

  @doc = """
    Declares teardown code that runs after each case in a `test` group.

    Assertions are non-fatal, so teardown still runs after assertion
    failures in the case body.
    """

  pub macro teardown(body :: Expr) -> Expr {
    quote { unquote(body) }
  }
}
