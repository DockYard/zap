pub module Test.ForComprehensionTest {
  use Zest.Case

  pub fn run() -> String {
    _doubled = for x <- [1, 2, 3] {
      x * 2
    }

    describe("for comprehension") {
      test("runs without error") {
        assert(true)
      }
    }
  }
}
