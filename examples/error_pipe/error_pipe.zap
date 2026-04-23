pub struct ErrorPipe {
  # Multi-clause function: only matches certain strings.
  # Unmatched inputs flow to the ~> catch basin.
  pub fn parse_number("one" :: String) -> String {
    "1"
  }

  pub fn parse_number("two" :: String) -> String {
    "2"
  }

  pub fn parse_number("three" :: String) -> String {
    "3"
  }

  # Single-clause function: always matches String.
  pub fn format_result(value :: String) -> String {
    "Result: " <> value
  }

  # ~> catches any value that doesn't match parse_number's clauses.
  # If input is "two", parse_number matches -> format_result runs -> "Result: 2"
  # If input is "invalid", parse_number doesn't match -> ~> handler runs -> "Error: unrecognized"
  pub fn process(input :: String) -> String {
    input
    |> parse_number()
    |> format_result()
    ~> {
      _ -> "Error: unrecognized"
    }
  }

  pub fn main(_args :: [String]) -> String {
    IO.puts(process("two"))
    IO.puts(process("invalid"))
  }
}
