@code Z9201
pub error IOError {}

@code Z9202
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %NetError{message: "down"}
  } rescue {
    e :: IOError -> "io"
    e :: NetError -> "net"
  }
  IO.puts(result)
  0
}
