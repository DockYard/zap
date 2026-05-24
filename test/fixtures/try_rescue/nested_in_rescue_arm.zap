@code Z9302
pub error IOError {}

@code Z9303
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %IOError{message: "outer boom"}
  } rescue {
    e :: IOError ->
      try {
        raise %NetError{message: "inner boom"}
      } rescue {
        n :: NetError -> "inner net caught"
      }
  }

  IO.puts(result)
  0
}
