@code Z9309
pub error IOError {}

@code Z9310
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    try {
      try {
        raise %NetError{message: "deep net"}
      } rescue {
        e :: IOError -> "depth3 only io"
      }
    } rescue {
      e :: IOError -> "depth2 only io"
    }
  } rescue {
    e :: NetError -> "depth1 caught net"
  }

  IO.puts(result)
  0
}
