@code Z9231
pub error NetError {}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %NetError{message: "down"}
  } rescue {
    _ -> "any"
  }
  IO.puts(result)
  0
}
