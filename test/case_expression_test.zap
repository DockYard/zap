pub struct CaseExpressionTest {
  use Zest.Case

  describe("case expressions") {
    test("matches integer literal one") {
      assert(label_number(1) == "one")
    }

    test("matches integer literal two") {
      assert(label_number(2) == "two")
    }

    test("falls through to default for other integers") {
      assert(label_number(99) == "other")
    }

    test("matches atom ok") {
      assert(status_message(:ok) == "all good")
    }

    test("matches atom error") {
      assert(status_message(:error) == "something went wrong")
    }

    test("falls through to default for other atoms") {
      assert(status_message(:pending) == "unknown status")
    }

    test("variable binding doubles non-zero value") {
      assert(add_or_zero(5) == 10)
    }

    test("matches zero literal") {
      assert(add_or_zero(0) == 0)
    }

    test("nested cases classify coordinate axes") {
      assert(classify_point(0, 0) == "origin")
      assert(classify_point(0, 5) == "y-axis")
      assert(classify_point(3, 0) == "x-axis")
      assert(classify_point(3, 5) == "plane")
    }

    # Boundary integer literals must round-trip to their exact value,
    # never silently fold to 0 (audit findings parser-1--01 / parser-2--02).
    # (The i64 MINIMUM `-9223372036854775808` cannot be written in
    # expression position — its magnitude overflows i64 storage, so it now
    # raises a diagnostic rather than folding to 0; its correct PATTERN-
    # position round-trip is pinned by the parser unit tests.)
    test("matches the i64 maximum literal in a case pattern") {
      assert(label_boundary(9223372036854775807) == "max")
      assert(label_boundary(1) == "other")
    }

    test("a valid i64 maximum literal is preserved in expression position") {
      assert(largest() == 9223372036854775807)
    }

    test("a hex literal round-trips to its decimal value") {
      assert(hex_mask() == 255)
    }

    test("an underscored literal round-trips to its value") {
      assert(million() == 1000000)
    }

    test("matches a hex literal in a case pattern") {
      assert(label_hex(255) == "all-ones-byte")
      assert(label_hex(1) == "other")
    }
  }

  # Regression for audit finding parser-2--01 / FE-02: pattern-position
  # string literals must go through the SAME escape processing and heredoc
  # stripping as expression-position string literals. Pre-fix, a case-arm
  # string pattern stored the RAW source slice (e.g. the 4 bytes `a`, `\`,
  # `n`, `b`), so it could NEVER match the actual 3-byte runtime string
  # built from the same `"a\nb"` literal — the arm was silently dead.
  describe("escaped string literals in case patterns") {
    test("a newline escape in a case pattern matches the real newline string") {
      assert(label_escaped("a\nb") == "newline")
    }

    test("a tab escape in a case pattern matches the real tab string") {
      assert(label_escaped("a\tb") == "tab")
    }

    test("an escaped quote in a case pattern matches the real quote string") {
      assert(label_escaped("a\"b") == "quote")
    }

    test("an escaped backslash in a case pattern matches the real backslash string") {
      assert(label_escaped("a\\b") == "backslash")
    }

    test("a non-escaped string still falls through to the default arm") {
      assert(label_escaped("plain") == "other")
    }

    test("a carriage-return + newline prefix matches in a case pattern") {
      assert(label_line_ending("\r\n") == "crlf")
      assert(label_line_ending("\n") == "lf")
    }

    test("an escaped string in a function-clause parameter dispatches correctly") {
      assert(clause_escaped("x\ty") == "clause-tab")
      assert(clause_escaped("nope") == "clause-other")
    }
  }

  fn label_boundary(x :: i64) -> String {
    case x {
      9223372036854775807 -> "max"
      _ -> "other"
    }
  }

  fn largest() -> i64 {
    9223372036854775807
  }

  fn hex_mask() -> i64 {
    0xFF
  }

  fn million() -> i64 {
    1_000_000
  }

  fn label_hex(x :: i64) -> String {
    case x {
      0xFF -> "all-ones-byte"
      _ -> "other"
    }
  }

  fn label_escaped(s :: String) -> String {
    case s {
      "a\nb" -> "newline"
      "a\tb" -> "tab"
      "a\"b" -> "quote"
      "a\\b" -> "backslash"
      _ -> "other"
    }
  }

  fn label_line_ending(s :: String) -> String {
    case s {
      "\r\n" -> "crlf"
      "\n" -> "lf"
      _ -> "other"
    }
  }

  fn clause_escaped("x\ty" :: String) -> String {
    "clause-tab"
  }

  fn clause_escaped(_ :: String) -> String {
    "clause-other"
  }

  fn label_number(x :: i64) -> String {
    case x {
      1 -> "one"
      2 -> "two"
      _ -> "other"
    }
  }

  fn status_message(s :: Atom) -> String {
    case s {
      :ok -> "all good"
      :error -> "something went wrong"
      _ -> "unknown status"
    }
  }

  fn add_or_zero(x :: i64) -> i64 {
    case x {
      0 -> 0
      n -> n + n
    }
  }

  fn classify_point(x :: i64, y :: i64) -> String {
    case x {
      0 -> case y {
        0 -> "origin"
        _ -> "y-axis"
      }
      _ -> case y {
        0 -> "x-axis"
        _ -> "plane"
      }
    }
  }
}
