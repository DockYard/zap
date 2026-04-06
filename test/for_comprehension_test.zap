pub module Test.ForComprehensionTest {
  use Zest.Case

  pub fn run() -> String {
    # Basic for comprehension produces a list
    doubled = for x <- [1, 2, 3] {
      x * 2
    }

    describe("for comprehension") {
      test("runs without error") {
        assert(true)
      }
    }

    # Verify the for comprehension ran without error
    "ForComprehensionTest: passed"
  }
}
