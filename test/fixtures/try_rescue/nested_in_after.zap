@code Z9311
pub error IOError {}

@code Z9312
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %IOError{message: "outer boom"}
  } rescue {
    e :: IOError -> "outer caught"
  } after {
    inner = try {
      raise %NetError{message: "after boom"}
    } rescue {
      n :: NetError -> "after-inner caught"
    }
    IO.puts(inner)
    IO.puts("cleanup ran")
  }

  IO.puts(result)
  0
}
