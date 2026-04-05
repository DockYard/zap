pub module Test.PatternMatchingTest {
  use Zest
  pub fn run() -> String {
    # Atom pattern matching
    assert(describe(:ok) == "success")
    assert(describe(:error) == "failure")
    assert(describe(:other) == "unknown")

    "PatternMatchingTest: passed"
  }

  fn describe(:ok :: Atom) -> String {
    "success"
  }

  fn describe(:error :: Atom) -> String {
    "failure"
  }

  fn describe(_ :: Atom) -> String {
    "unknown"
  }
}
