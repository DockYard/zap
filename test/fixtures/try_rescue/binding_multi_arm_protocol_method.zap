@code Z9341
pub error IOError {
  message :: String = "io"
}

@code Z9342
pub error NetError {
  message :: String = "net"
}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %NetError{message: "connection refused"}
  } rescue {
    e :: IOError -> Error.message(e)
    e :: NetError -> Error.message(e)
  }
  IO.puts(result)
  0
}
