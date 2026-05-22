@code Z9301
pub error IOError {}

pub struct Worker {
  fn deep() -> String raises IOError {
    raise %IOError{message: "disk gone"}
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    Worker.deep()
  } rescue {
    e :: IOError -> "caught"
  }
  IO.puts(result)
  0
}
