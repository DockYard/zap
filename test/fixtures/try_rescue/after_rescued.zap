@code Z9101
pub error IOError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %IOError{message: "boom"}
  } rescue {
    e :: IOError -> "caught"
  } after {
    IO.puts("cleanup ran")
  }
  IO.puts(result)
  0
}
