pub module Test.PatternMatchingTest {
  use Zest.Case

  pub fn run() -> String {
    describe("pattern matching") {
      test("matches ok atom to success") {
        assert(describe(:ok) == "success")
      }

      test("matches error atom to failure") {
        assert(describe(:error) == "failure")
      }

      test("matches wildcard atom to unknown") {
        assert(describe(:other) == "unknown")
      }
    }
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
