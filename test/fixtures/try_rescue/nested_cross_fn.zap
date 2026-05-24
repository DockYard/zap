@code Z9307
pub error IOError {}

pub struct Worker {
  fn deep() -> String raises IOError {
    raise %IOError{message: "disk gone"}
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    inner = try {
      Worker.deep()
    } rescue {
      e :: IOError -> "inner caught cross-fn"
    }
    inner
  } rescue {
    e :: IOError -> "outer caught"
  }

  IO.puts(result)
  0
}
