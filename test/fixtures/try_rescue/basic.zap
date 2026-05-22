@code Z9001
pub error IOError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %IOError{message: "disk gone"}
  } rescue {
    e :: IOError -> "caught"
  }

  IO.puts(result)
  0
}
