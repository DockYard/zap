@code Z9301
pub error IOError {}

fn main(args :: [String]) -> u8 {
  result = try {
    inner = try {
      raise %IOError{message: "inner boom"}
    } rescue {
      e :: IOError -> "inner caught"
    }
    IO.puts(inner)
    "outer body done"
  } rescue {
    e :: IOError -> "outer caught"
  }

  IO.puts(result)
  0
}
