pub module Test.PipesTest {
  use Zest
  pub fn run() -> String {
    # Basic pipe
    assert((5 |> add_one()) == 6)

    # Multi-step pipe
    assert((5 |> add_one() |> add_one()) == 7)

    # Pipe with string functions
    assert(("hello" |> shout()) == "hello!")

    "PipesTest: passed"
  }

  fn add_one(x :: i64) -> i64 {
    x + 1
  }

  fn shout(s :: String) -> String {
    s <> "!"
  }
}
