pub module Test.MultiArityTest {
  use Zest

  pub fn run() -> String {
    # Functions with different arities
    assert(add(1, 2) == 3)
    assert(add3(1, 2, 3) == 6)

    # Multi-parameter string functions
    assert(join("hello", " ", "world") == "hello world")

    "MultiArityTest: passed"
  }

  fn add(a :: i64, b :: i64) -> i64 {
    a + b
  }

  fn add3(a :: i64, b :: i64, c :: i64) -> i64 {
    a + b + c
  }

  fn join(a :: String, sep :: String, b :: String) -> String {
    a <> sep <> b
  }
}
