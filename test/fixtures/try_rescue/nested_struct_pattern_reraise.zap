@code Z9308
pub error IOError {}

fn main(args :: [String]) -> u8 {
  result = try {
    try {
      raise %IOError{message: "struct boom"}
    } rescue {
      %IOError{message: m} -> raise %IOError{message: m}
    }
  } rescue {
    e :: IOError -> "outer caught struct reraise"
  }

  IO.puts(result)
  0
}
