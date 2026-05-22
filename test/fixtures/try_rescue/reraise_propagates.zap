@code Z9103
pub error IOError {}

fn main(args :: [String]) -> u8 {
  try {
    raise %IOError{message: "disk gone"}
  } rescue {
    e :: IOError -> raise e
  }
  0
}
