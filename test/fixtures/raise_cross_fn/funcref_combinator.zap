pub struct Doubler {
  pub fn double(x :: i64) -> i64 {
    x * 2
  }
}

fn main(args :: [String]) -> u8 {
  doubled = Enum.map([1, 2, 3], &Doubler.double/1)
  total = Enum.reduce(doubled, 0, fn(acc :: i64, x :: i64) -> i64 { acc + x })
  IO.puts(Integer.to_string(total))
  0
}
