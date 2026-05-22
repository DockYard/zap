# Phase 1.4: the catch-basin `~>` operator still works end-to-end.
#
# Ports the core of test/catch_basin_test.zap to script mode. `parse/1`
# is a multi-clause function that only matches "one"/"two"; piping an
# unmatched value into it via `|>` and catching with `~>` runs the
# handler with the unmatched value bound.
#
# Exercises (behaviour the Phase 1.4 `~>`-over-Result work must preserve):
#   * matched value passes straight through the pipe;
#   * unmatched value is intercepted by the `~>` handler;
#   * the handler binds the failing piped value (`val`);
#   * a multi-step pipe skips remaining steps on failure.
#
# Expected output:
#
#     1
#     unmatched: nope
#     formatted: valid
#     rejected: bad

pub struct Demo {
  fn parse("one" :: String) -> String {
    "1"
  }

  fn parse("two" :: String) -> String {
    "2"
  }

  fn try_parse(input :: String) -> String {
    input
    |> parse()
    ~> {
      val -> "unmatched: " <> val
    }
  }

  fn validate("good" :: String) -> String {
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
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Demo.try_parse("one"))
  IO.puts(Demo.try_parse("nope"))
  IO.puts(Demo.try_pipeline("good"))
  IO.puts(Demo.try_pipeline("bad"))
  0
}
