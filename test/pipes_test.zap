pub struct PipesTest {
  use Zest.Case

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

    test("pipe chain into Integer.to_string") {
      assert((5 |> double() |> add_one() |> Integer.to_string()) == "11")
    }

    test("multi-clause function result pipes into conversion") {
      assert((factorial(10) |> Integer.to_string()) == "3628800")
    }
  }

  fn add_one(x :: i64) -> i64 {
    x + 1
  }

  fn double(x :: i64) -> i64 {
    x * 2
  }

  fn shout(s :: String) -> String {
    s <> "!"
  }

  fn factorial(0 :: i64) -> i64 {
    1
  }

  fn factorial(n :: i64) -> i64 {
    n * factorial(n - 1)
  }
}
