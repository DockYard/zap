@code Z9261
pub error AErr {}

@code Z9262
pub error BErr {}

fn main(args :: [String]) -> u8 {
  n = 1
  case n {
    1 -> raise %AErr{message: "a"}
    _ -> raise %BErr{message: "b"}
  }
  0
}
