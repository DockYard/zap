@code Z9306
pub error IOError {}

fn main(args :: [String]) -> u8 {
  result = try {
    middle = try {
      inner = try {
        raise %IOError{message: "deep boom"}
      } rescue {
        e :: IOError -> "depth3 caught"
      }
      inner
    } rescue {
      e :: IOError -> "depth2 caught"
    }
    middle
  } rescue {
    e :: IOError -> "depth1 caught"
  }

  IO.puts(result)
  0
}
