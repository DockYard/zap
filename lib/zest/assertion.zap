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
    truthy_result(kind, code, value, result, custom_message, "")
  }

  @doc = """
    Records the result of a truthy assertion or rejection with a source location.

    `location` is a `file:line` string captured at macro expansion time.
    It is included in the rendered failure report when available.
    """

  pub fn truthy_result(kind :: String, code :: String, value :: String, result :: Bool, custom_message :: String, location :: String) -> String {
    passed = if kind == "assert" {
      result
    } else {
      not result
    }

    if passed {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion_with_message(format_truthy_failure(kind, code, value, custom_message, location))
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
    comparison_result(kind, operator, code, left_label, left_value, right_label, right_value, comparison_result, custom_message, "")
  }

  @doc = """
    Records the result of a comparison assertion or rejection with a source location.

    `location` is a `file:line` string captured at macro expansion time.
    It is included in the rendered failure report when available.
    """

  pub fn comparison_result(kind :: String, operator :: String, code :: String, left_label :: String, left_value :: String, right_label :: String, right_value :: String, comparison_result :: Bool, custom_message :: String, location :: String) -> String {
    passed = if kind == "assert" {
      comparison_result
    } else {
      not comparison_result
    }

    if passed {
      :zig.Zest.pass_assertion()
      "."
    } else {
      :zig.Zest.fail_assertion_with_message(format_comparison_failure(kind, operator, code, left_label, left_value, right_label, right_value, comparison_result, custom_message, location))
      "F"
    }
  }

  @doc = """
    Records the result of an `assert_no_leaks { <block> }` assertion.

    `before_count`/`after_count` are the live-allocation counts sampled by the
    macro immediately before and after the block; `before_bytes`/`after_bytes`
    are the matching byte totals. `tracking_active` is whether the active
    memory manager could answer the query at all.

    When `tracking_active` is `false` (the test target does not select
    `Memory.Tracking`), the assertion PASSES as a documented no-op — there is
    no live-set to checkpoint, so a leak is not observable here. Otherwise the
    net rise in live allocations (`after_count - before_count`) is the set of
    allocations the block made and abandoned: zero passes; a positive delta
    fails with the leaked count + bytes rendered as the failure detail.
    """

  pub fn no_leaks_result(tracking_active :: Bool, before_count :: i64, after_count :: i64, before_bytes :: i64, after_bytes :: i64, code :: String, location :: String) -> String {
    if not tracking_active {
      :zig.Zest.pass_assertion()
      "."
    } else {
      leaked_count = after_count - before_count
      leaked_bytes = after_bytes - before_bytes

      if would_report_leak?(leaked_count) {
        :zig.Zest.fail_assertion_with_message(format_leak_failure(leaked_count, leaked_bytes, code, location))
        "F"
      } else {
        :zig.Zest.pass_assertion()
        "."
      }
    }
  }

  @doc = """
    Pure decision: would an `assert_no_leaks` block with the given net live-
    allocation delta be reported as a leak? `true` for a positive delta (the
    block left allocations live), `false` otherwise. Side-effect-free — the
    recording in `no_leaks_result` delegates to this so the polarity is unit-
    testable without touching the live test tracker.
    """

  pub fn would_report_leak?(leaked_count :: i64) -> Bool {
    leaked_count > 0
  }

  @doc = """
    Records the result of an `@expect_leak`-inverted leak assertion.

    Used for a test marked `@expect_leak`: the test is EXPECTED to leak, so the
    polarity of `no_leaks_result` is inverted. A positive net live-allocation
    delta (the expected leak occurred) PASSES; a zero delta FAILS, because a
    test that claims it leaks but does not is a stale expectation that should be
    removed. When the manager cannot answer (`tracking_active == false`), the
    assertion passes as a no-op (the expectation cannot be checked here).
    """

  pub fn expect_leak_result(tracking_active :: Bool, before_count :: i64, after_count :: i64, _before_bytes :: i64, _after_bytes :: i64, code :: String, location :: String) -> String {
    if not tracking_active {
      :zig.Zest.pass_assertion()
      "."
    } else {
      leaked_count = after_count - before_count

      if leaked_count > 0 {
        :zig.Zest.pass_assertion()
        "."
      } else {
        :zig.Zest.fail_assertion_with_message(format_expected_leak_failure(code, location))
        "F"
      }
    }
  }

  fn format_leak_failure(leaked_count :: i64, leaked_bytes :: i64, code :: String, location :: String) -> String {
    "memory leak assertion failed" <> location_block(location) <> "\nblock: " <> display_text(code, "block") <> "\nleaked: " <> Kernel.to_string(leaked_count) <> " allocation(s), " <> Kernel.to_string(leaked_bytes) <> " bytes\nexpected: 0 net live allocations after the block"
  }

  fn format_expected_leak_failure(code :: String, location :: String) -> String {
    "@expect_leak assertion failed" <> location_block(location) <> "\nblock: " <> display_text(code, "block") <> "\nresult: the block did not leak, but it was marked @expect_leak\nexpected: at least one net live allocation to remain"
  }

  fn format_truthy_failure(kind :: String, code :: String, value :: String, custom_message :: String, location :: String) -> String {
    heading(kind) <> location_block(location) <> "\ncode: " <> display_text(code, "expression") <> "\nvalue: " <> value <> custom_message_block(custom_message)
  }

  fn format_comparison_failure(kind :: String, operator :: String, code :: String, left_label :: String, left_value :: String, right_label :: String, right_value :: String, comparison_result :: Bool, custom_message :: String, location :: String) -> String {
    heading(kind) <> location_block(location) <> "\ncode: " <> display_text(code, "comparison") <> "\noperator: " <> operator <> "\nleft: " <> display_text(left_label, "left") <> " = " <> left_value <> "\nright: " <> display_text(right_label, "right") <> " = " <> right_value <> "\nresult: " <> Kernel.to_string(comparison_result) <> custom_message_block(custom_message)
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

  fn location_block(location :: String) -> String {
    if location == "" {
      ""
    } else {
      "\nlocation: " <> location
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
