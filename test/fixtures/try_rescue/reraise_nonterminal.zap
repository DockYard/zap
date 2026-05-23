@code Z9251
pub error IOError {}

@code Z9252
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %IOError{message: "disk"}
  } rescue {
    e :: IOError -> raise e
    e :: NetError -> "net"
  }
  IO.puts(result)
  0
}
