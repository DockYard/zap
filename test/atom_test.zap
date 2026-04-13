pub module Test.AtomTest {
  use Zest.Case

  describe("Atom module") {
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

    test("to_string converts atom") {
      assert(Atom.to_string(:hello) == "hello")
    }

    test("to_string converts ok") {
      assert(Atom.to_string(:ok) == "ok")
    }

    test("from_string creates atom") {
      assert(Atom.from_string("ok") == :ok)
    }

    test("from_string roundtrip") {
      assert(Atom.to_string(Atom.from_string("test")) == "test")
    }
  }

  fn status(:ok :: Atom) -> String {
    "success"
  }

  fn status(:error :: Atom) -> String {
    "failure"
  }
}
