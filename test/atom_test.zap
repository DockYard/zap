pub module Test.AtomTest {
  use Zest.Case

  pub fn run() -> String {
    describe("atoms") {
      test("equal atoms match") {
        assert(:ok == :ok)
      }

      test("error atoms match") {
        assert(:error == :error)
      }

      test("different atoms do not match") {
        reject(:ok == :error)
      }

      test("status function returns success for ok") {
        assert(status(:ok) == "success")
      }

      test("status function returns failure for error") {
        assert(status(:error) == "failure")
      }
    }
  }

  fn status(:ok :: Atom) -> String {
    "success"
  }

  fn status(:error :: Atom) -> String {
    "failure"
  }
}
