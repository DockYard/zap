@code Z9211
pub error IOError {}

@code Z9212
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %IOError{message: "disk"}
  } rescue {
    e :: IOError -> "io"
    e :: NetError -> "net"
  }
  IO.puts(result)
  0
}
