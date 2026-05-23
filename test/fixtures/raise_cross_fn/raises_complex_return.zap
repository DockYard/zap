@code Z9601
pub error BoomError {}

pub struct Maker {
  pub fn make(n :: i64) -> [i64] raises BoomError {
    case n {
      0 -> raise %BoomError{message: "zero"}
      _ -> [n, n, n]
    }
  }
}

fn main(args :: [String]) -> u8 {
  result = try {
    xs = Maker.make(0)
    "made a list"
  } rescue {
    e :: BoomError -> "boom caught"
  }
  IO.puts(result)
  0
}
