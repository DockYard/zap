@doc = """
  Assertion result helpers for Zest.

  The public functions receive structured assertion data from
  macro-expanded `assert` and `reject` calls, decide whether the
  assertion passed, and record either a pass or a rich rendered
  failure message with the runtime test tracker.
  """

pub struct Zest.Assertion {
  @doc = """
    Records the result of a truthy assertion or rejection.

    `kind` is `"assert"` or `"reject"`. `code` is the source text for
    the asserted expression when available. `value` is the already
    rendered value of the expression, and `result` is the boolean value
    used to decide pass/fail.
    """

  pub fn truthy_result(kind :: String, code :: String, value :: String, result :: Bool, custom_message :: String) -> String {
    passed = if kind == "assert" {
      result
    } else {
      not result
    }

    if passed {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion_with_message(format_truthy_failure(kind, code, value, custom_message))
      "F"
    }
  }

  @doc = """
    Records the result of a comparison assertion or rejection.

    `kind` is `"assert"` or `"reject"`. `operator`, `code`,
    `left_label`, `left_value`, `right_label`, and `right_value`
    describe the comparison. `comparison_result` is the boolean result
    of evaluating the comparison exactly once.
    """

  pub fn comparison_result(kind :: String, operator :: String, code :: String, left_label :: String, left_value :: String, right_label :: String, right_value :: String, comparison_result :: Bool, custom_message :: String) -> String {
    passed = if kind == "assert" {
      comparison_result
    } else {
      not comparison_result
    }

    if passed {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion_with_message(format_comparison_failure(kind, operator, code, left_label, left_value, right_label, right_value, comparison_result, custom_message))
      "F"
    }
  }

  fn format_truthy_failure(kind :: String, code :: String, value :: String, custom_message :: String) -> String {
    heading(kind) <> "\ncode: " <> display_text(code, "expression") <> "\nvalue: " <> value <> custom_message_block(custom_message)
  }

  fn format_comparison_failure(kind :: String, operator :: String, code :: String, left_label :: String, left_value :: String, right_label :: String, right_value :: String, comparison_result :: Bool, custom_message :: String) -> String {
    heading(kind) <> "\ncode: " <> display_text(code, "comparison") <> "\noperator: " <> operator <> "\nleft: " <> display_text(left_label, "left") <> " = " <> left_value <> "\nright: " <> display_text(right_label, "right") <> " = " <> right_value <> "\nresult: " <> Kernel.to_string(comparison_result) <> custom_message_block(custom_message)
  }

  fn heading(kind :: String) -> String {
    if kind == "assert" {
      "assertion failed"
    } else {
      "rejection failed"
    }
  }

  fn display_text(value :: String, fallback :: String) -> String {
    if value == "" {
      fallback
    } else {
      value
    }
  }

  fn custom_message_block(custom_message :: String) -> String {
    if custom_message == "" {
      ""
    } else {
      "\nmessage: " <> custom_message
    }
  }
}
