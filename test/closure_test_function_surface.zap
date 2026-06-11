pub struct ClosureTestFunctionSurface {
  pub fn run_nullary(callback :: fn() -> i64) -> i64 {
    callback()
  }

  pub fn run_binary(callback :: fn(i64, i64) -> i64) -> i64 {
    callback(3, 4)
  }

  pub fn make() -> fn() -> i64 {
    fn() -> i64 { 8 }
  }

  pub fn make_five() -> fn() -> i64 {
    fn() -> i64 { 5 }
  }
}
