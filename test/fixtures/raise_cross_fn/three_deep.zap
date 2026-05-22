@code Z9302
pub error IOError {}

pub struct Chain {
  fn c() -> String raises IOError {
    raise %IOError{message: "bottom"}
  }

  fn b() -> String raises IOError {
    Chain.c()
  }

  fn a() -> String raises IOError {
    Chain.b()
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    Chain.a()
  } rescue {
    e :: IOError -> "caught at top"
  }
  IO.puts(result)
  0
}
