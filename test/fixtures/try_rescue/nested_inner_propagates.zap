@code Z9304
pub error IOError {}

@code Z9305
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    try {
      raise %NetError{message: "inner net"}
    } rescue {
      e :: IOError -> "inner only handles io"
    }
  } rescue {
    e :: NetError -> "outer caught net"
  }

  IO.puts(result)
  0
}
