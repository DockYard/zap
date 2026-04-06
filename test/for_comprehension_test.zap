pub module Test.ForComprehensionTest {
  use Zest

  pub fn run() -> String {
    # Basic for comprehension produces a list
    doubled = for x <- [1, 2, 3] {
      x * 2
    }
    # Verify the for comprehension ran without error
    "ForComprehensionTest: passed"
  }
}
