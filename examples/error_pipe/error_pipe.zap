pub module ErrorPipe {
  # Result union for fallible string operations
  pub union ParseResult {
    Ok :: String
    Error :: Atom
  }

  # A function that can fail — returns ParseResult
  pub fn parse_number(input :: String) -> ParseResult {
    case input {
      "one" -> ParseResult.Ok("1")
      "two" -> ParseResult.Ok("2")
      "three" -> ParseResult.Ok("3")
      _ -> ParseResult.Error(:unknown_number)
    }
  }

  # A function that transforms successfully parsed values
  pub fn format_result(value :: String) -> String {
    "Result: " <> value
  }

  # Error pipe with inline block handler
  pub fn process(input :: String) -> String {
    parse_number(input)
    |> format_result()
    ~> {
      :unknown_number -> "Error: unrecognized number"
    }
  }

  # Error pipe with function handler
  pub fn process_with_handler(input :: String) -> String {
    parse_number(input)
    |> format_result()
    ~> handle_error()
  }

  fn handle_error(err :: Atom) -> String {
    case err {
      :unknown_number -> "Handled: unknown number"
      _ -> "Handled: unexpected error"
    }
  }

  # Result union for validation
  pub union ValidateResult {
    Ok :: String
    Error :: Atom
  }

  # Chaining multiple fallible steps
  pub fn check_not_empty(input :: String) -> ValidateResult {
    case input {
      "" -> ValidateResult.Error(:empty_input)
      _ -> ValidateResult.Ok(input)
    }
  }

  pub fn validate_and_process(input :: String) -> String {
    check_not_empty(input)
    |> parse_number()
    |> format_result()
    ~> {
      :empty_input -> "Error: input was empty"
      :unknown_number -> "Error: not a valid number"
    }
  }

  pub fn main(_args :: [String]) -> String {
    IO.puts(process("two"))
    IO.puts(process("invalid"))
    IO.puts(validate_and_process(""))
    IO.puts(validate_and_process("three"))
  }
}
