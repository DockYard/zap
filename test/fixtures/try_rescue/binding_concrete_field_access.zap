@code Z9321
pub error HttpError {
  status :: i64 = 0
}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %HttpError{status: 404, message: "not found"}
  } rescue {
    e :: HttpError -> Integer.to_string(e.status)
  }
  IO.puts(result)
  0
}
