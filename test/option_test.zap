pub struct OptionTest {
  use Zest.Case

  describe("Option(T) — construction") {
    test("Option(i64).Some(42) constructs without crashing") {
      _ = Option(i64).Some(42)
      assert(true)
    }

    test("Option(i64).None constructs without crashing") {
      _ = Option(i64).None
      assert(true)
    }

    test("Option(String).Some accepts a String payload") {
      _ = Option(String).Some("hi")
      assert(true)
    }
  }
}
