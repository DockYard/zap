pub module ErrorPipe {
  # A function that can fail — returns String or Err(Atom)
  pub fn parse_number(input :: String) -> String | Err(Atom) {
    case input {
      "one" -> "1"
      "two" -> "2"
      "three" -> "3"
      _ -> Err(:unknown_number)
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

  # Chaining multiple fallible steps
  pub fn validate_and_process(input :: String) -> String {
    check_not_empty(input)
    |> parse_number()
    |> format_result()
    ~> {
      :empty_input -> "Error: input was empty"
      :unknown_number -> "Error: not a valid number"
    }
  }

  pub fn check_not_empty(input :: String) -> String | Err(Atom) {
    case input {
      "" -> Err(:empty_input)
      _ -> input
    }
  }

  pub fn main(_args :: [String]) -> String {
    IO.puts(process("two"))
    IO.puts(process("invalid"))
    IO.puts(validate_and_process(""))
    IO.puts(validate_and_process("three"))
  }
}
