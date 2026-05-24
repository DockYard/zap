@code Z9106
pub error IOError {}

pub struct Risky {
  pub fn run() -> u8 raises IOError {
    try {
      raise %IOError{message: "disk gone"}
    } rescue {
      e :: IOError -> raise e
    } after {
      IO.puts("cleanup ran")
    }
    0
  }
}

fn main(args :: [String]) -> u8 {
  Risky.run()
  0
}
