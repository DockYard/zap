pub module Test.CatchBasinTest {
  use Zest

  pub fn run() -> String {
    # Matching value passes through
    assert(try_parse("one") == "1")
    assert(try_parse("two") == "2")

    # Unmatched value goes to handler
    assert(try_parse("nope") == "unmatched: nope")
    assert(try_parse("xyz") == "unmatched: xyz")

    # Handler can pattern match on the unmatched value
    assert(try_with_patterns("one") == "1")
    assert(try_with_patterns("bad") == "got bad")
    assert(try_with_patterns("other") == "unknown: other")

    # Short-circuits remaining pipe steps
    assert(try_pipeline("good") == "formatted: valid")
    assert(try_pipeline("bad") == "rejected: bad")

    "CatchBasinTest: passed"
  }

  # Multi-clause function — only matches specific strings
  fn parse("one" :: String) -> String {
    "1"
  }

  fn parse("two" :: String) -> String {
    "2"
  }

  # Basic catch basin — unmatched value bound to variable
  fn try_parse(input :: String) -> String {
    input
    |> parse()
    ~> {
      val -> "unmatched: " <> val
    }
  }

  # Handler with pattern matching on the unmatched value
  fn try_with_patterns(input :: String) -> String {
    input
    |> parse()
    ~> {
      "bad" -> "got bad"
      other -> "unknown: " <> other
    }
  }

  # Multi-step pipe — handler skips remaining steps
  fn validate("good" :: String) -> String {
    "valid"
  }

  fn format(s :: String) -> String {
    "formatted: " <> s
  }

  fn try_pipeline(input :: String) -> String {
    input
    |> validate()
    |> format()
    ~> {
      val -> "rejected: " <> val
    }
  }
}
