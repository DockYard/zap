pub module Test.PipesTest {
  use Zest.Case

  pub fn run() -> String {
    describe("pipes") {
      test("basic pipe adds one") {
        assert((5 |> add_one()) == 6)
      }

      test("multi-step pipe chains") {
        assert((5 |> add_one() |> add_one()) == 7)
      }

      test("pipe with string function") {
        assert(("hello" |> shout()) == "hello!")
      }
    }
  }

  fn add_one(x :: i64) -> i64 {
    x + 1
  }

  fn shout(s :: String) -> String {
    s <> "!"
  }
}
