fn main(args :: [String]) -> u8 {
  result = try {
    "ok"
  } rescue {
    e :: RuntimeError -> "rescued"
  } after {
    IO.puts("cleanup ran")
  }
  IO.puts(result)
  0
}
