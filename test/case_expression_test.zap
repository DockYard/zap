pub module Test.CaseExpressionTest {
  use Zest.Case

  describe("case expressions") {
    test("matches integer literal one") {
      assert(label_number(1) == "one")
    }

    test("matches integer literal two") {
      assert(label_number(2) == "two")
    }

    test("falls through to default for other integers") {
      assert(label_number(99) == "other")
    }

    test("matches atom ok") {
      assert(status_message(:ok) == "all good")
    }

    test("matches atom error") {
      assert(status_message(:error) == "something went wrong")
    }

    test("falls through to default for other atoms") {
      assert(status_message(:pending) == "unknown status")
    }

    test("variable binding doubles non-zero value") {
      assert(add_or_zero(5) == 10)
    }

    test("matches zero literal") {
      assert(add_or_zero(0) == 0)
    }
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
