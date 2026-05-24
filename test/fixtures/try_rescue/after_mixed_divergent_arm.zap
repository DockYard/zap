@code Z9107
pub error IOError {}

@code Z9108
pub error NetError {}

fn main(args :: [String]) -> u8 {
  try {
    raise %NetError{message: "timeout"}
  } rescue {
    e :: IOError -> "io recovered"
    e :: NetError -> raise e
  } after {
    IO.puts("cleanup ran")
  }
  0
}
