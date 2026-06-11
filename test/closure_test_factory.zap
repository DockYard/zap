pub struct ClosureTestFactory {
  pub fn make_adder() -> fn() -> i64 {
    fn() -> i64 { 42 }
  }

  pub fn build_handler() -> ClosureTestHandler {
    %ClosureTestHandler{action: fn() -> i64 { 99 }}
  }
}
