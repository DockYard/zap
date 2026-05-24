@code Z9301
pub error KeyError {
  key :: Atom
}

fn main(args :: [String]) -> u8 {
  result = try {
    raise %KeyError{key: :missing, message: "absent"}
  } rescue {
    %KeyError{key: k} -> Atom.to_string(k)
  }
  IO.puts("recovered-ok=" <> result)
  0
}
