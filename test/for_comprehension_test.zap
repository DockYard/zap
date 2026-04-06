pub module Test.ForComprehensionTest {
  use Zest

  pub fn run() -> String {
    doubled = for x <- [1, 2, 3] {
      x * 2
    }
    assert(sum(doubled) == 12)
    "ForComprehensionTest: passed"
  }

  fn sum([] :: [i64]) -> i64 {
    0
  }

  fn sum([h | t] :: [i64]) -> i64 {
    h + sum(t)
  }
}
