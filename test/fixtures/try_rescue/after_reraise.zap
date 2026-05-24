@code Z9104
pub error IOError {}

fn main(args :: [String]) -> u8 {
  try {
    raise %IOError{message: "disk gone"}
  } rescue {
    e :: IOError -> raise e
  } after {
    IO.puts("cleanup ran")
  }
  0
}
