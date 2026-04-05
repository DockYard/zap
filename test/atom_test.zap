pub module Test.AtomTest {
  use Zest
  pub fn run() -> String {
    # Atom equality
    assert(:ok == :ok)
    assert(:error == :error)
    reject(:ok == :error)

    # Atom in functions
    assert(status(:ok) == "success")
    assert(status(:error) == "failure")

    "AtomTest: passed"
  }

  fn status(:ok :: Atom) -> String {
    "success"
  }

  fn status(:error :: Atom) -> String {
    "failure"
  }
}
