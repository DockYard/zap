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

  describe("Option(T) — predicates") {
    test("is_some?/1 returns true for Some") {
      assert(Option.is_some?(Option(i64).Some(42)) == true)
    }

    test("is_some?/1 returns false for None") {
      assert(Option.is_some?(Option(i64).None) == false)
    }

    test("is_none?/1 returns true for None") {
      assert(Option.is_none?(Option(i64).None) == true)
    }

    test("is_none?/1 returns false for Some") {
      assert(Option.is_none?(Option(i64).Some(42)) == false)
    }
  }

  describe("Option(T) — unwrap_or/2") {
    test("returns the payload of Some") {
      assert(Option.unwrap_or(Option(i64).Some(42), 0) == 42)
    }

    test("returns the default for None") {
      assert(Option.unwrap_or(Option(i64).None, 7) == 7)
    }
  }

  describe("Option(T) — case-arm destructuring") {
    test("Option.Some(v) -> v extracts the i64 payload") {
      result = case Option(i64).Some(42) {
        Option.Some(v) -> v
        Option.None -> 0
      }
      assert(result == 42)
    }

    test("Option.None -> 0 matches the nullary arm") {
      result = case Option(i64).None {
        Option.Some(v) -> v
        Option.None -> 0
      }
      assert(result == 0)
    }
  }
}
