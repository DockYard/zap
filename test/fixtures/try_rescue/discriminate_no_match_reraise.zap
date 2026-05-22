@code Z9241
pub error IOError {}

@code Z9242
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %NetError{message: "down"}
  } rescue {
    e :: IOError -> "io"
  }
  IO.puts(result)
  0
}
