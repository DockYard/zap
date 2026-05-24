@code Z9331
pub error MyError {
  message :: String = "boom"
}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %MyError{message: "boom"}
  } rescue {
    e -> Error.message(e)
  }
  IO.puts(result)
  0
}
