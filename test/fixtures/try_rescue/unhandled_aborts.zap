@code Z9112
pub error IOError {}

fn main(args :: [String]) -> u8 {
  raise %IOError{message: "no handler here"}
  0
}
