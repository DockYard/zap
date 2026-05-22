@code Z9303
pub error IOError {}

pub struct Worker {
  fn deep() -> String raises IOError {
    raise %IOError{message: "no handler anywhere"}
  }
}

fn main(args :: [String]) -> u8 {
  msg = Worker.deep()
  IO.puts(msg)
  0
}
