@code Z9304
pub error IOError {}

@code Z9305
pub error NetError {}

pub struct Worker {
  fn deep() -> String raises NetError {
    raise %NetError{message: "timeout"}
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    Worker.deep()
  } rescue {
    e :: IOError -> "io"
    e :: NetError -> "net"
  }
  IO.puts(result)
  0
}
