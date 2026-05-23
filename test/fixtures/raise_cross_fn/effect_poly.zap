@code Z9601
pub error ParseError {}

pub struct Parser {
  pub fn parse_one(s :: String) -> i64 raises ParseError {
    case s {
      "" -> raise %ParseError{message: "empty input"}
      _ -> Integer.parse(s)
    }
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    parsed = Enum.map(["1", "", "3"], &Parser.parse_one/1)
    "all parsed"
  } rescue {
    e :: ParseError -> "parse failed"
  }
  IO.puts(result)
  0
}
