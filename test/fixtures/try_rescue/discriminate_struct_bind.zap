@code Z9221
pub error KeyError {
  key :: Atom
}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %KeyError{key: :x, message: "missing"}
  } rescue {
    %KeyError{key: k} -> Atom.to_string(k)
  }
  IO.puts(result)
  0
}
