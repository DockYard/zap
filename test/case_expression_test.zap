pub module Test.CaseExpressionTest {
  use Zest
  pub fn run() -> String {
    # Case with integer literals
    assert(label_number(1) == "one")
    assert(label_number(2) == "two")
    assert(label_number(99) == "other")

    # Case with atom literals
    assert(status_message(:ok) == "all good")
    assert(status_message(:error) == "something went wrong")
    assert(status_message(:pending) == "unknown status")

    # Case with variable binding
    assert(add_or_zero(5) == 10)
    assert(add_or_zero(0) == 0)

    "CaseExpressionTest: passed"
  }

  fn label_number(x :: i64) -> String {
    case x {
      1 -> "one"
      2 -> "two"
      _ -> "other"
    }
  }

  fn status_message(s :: Atom) -> String {
    case s {
      :ok -> "all good"
      :error -> "something went wrong"
      _ -> "unknown status"
    }
  }

  fn add_or_zero(x :: i64) -> i64 {
    case x {
      0 -> 0
      n -> n + n
    }
  }
}
