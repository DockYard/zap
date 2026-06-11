pub struct CatchBasinTest {
  use Zest.Case

  describe("catch basins") {
    test("matching value passes through for one") {
      assert(try_parse("one") == "1")
    }

    test("matching value passes through for two") {
      assert(try_parse("two") == "2")
    }

    test("unmatched value goes to handler") {
      assert(try_parse("nope") == "unmatched: nope")
    }

    test("another unmatched value goes to handler") {
      assert(try_parse("xyz") == "unmatched: xyz")
    }

    test("handler pattern matches on unmatched value") {
      assert(try_with_patterns("one") == "1")
      assert(try_with_patterns("bad") == "got bad")
      assert(try_with_patterns("xyz") == "unknown: xyz")
    }

    test("short-circuits multi-step pipes") {
      assert(try_pipeline("good") == "formatted: valid")
      assert(try_pipeline("bad") == "rejected: bad")
    }

    test("function handler receives unmatched value") {
      assert(try_fn_handler("one") == "1")
      assert(try_fn_handler("bad") == "error: bad")
    }

    test("function handler with extra args receives unmatched value") {
      assert(try_fn_handler_extra("one") == "1")
      assert(try_fn_handler_extra("nope") == "fallback: nope")
    }
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

  # Multi-step pipe — validate only matches specific values
  fn validate("good" :: String) -> String {
    "valid"
  }

  fn validate("ok" :: String) -> String {
    "valid"
  }

  fn format_result(value :: String) -> String {
    "formatted: " <> value
  }

  fn try_pipeline(input :: String) -> String {
    input
    |> validate()
    |> format_result()
    ~> {
      val -> "rejected: " <> val
    }
  }

  # Function handler — unmatched value injected as first arg
  fn handle_error(val :: String) -> String {
    "error: " <> val
  }

  fn try_fn_handler(input :: String) -> String {
    input
    |> parse()
    ~> handle_error()
  }

  # Function handler with extra args
  fn fallback(val :: String, prefix :: String) -> String {
    prefix <> val
  }

  fn try_fn_handler_extra(input :: String) -> String {
    input
    |> parse()
    ~> fallback("fallback: ")
  }
}
