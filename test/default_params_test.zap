pub struct DefaultParamsTest {
  use Zest.Case

  describe("default params") {
    test("integer default is used when arg omitted") {
      assert(add(5) == 15)
    }

    test("integer default is overridden when arg provided") {
      assert(add(5, 20) == 25)
    }

    test("string default is used when arg omitted") {
      assert(greet("World") == "Hello, World!")
    }

    test("string default is overridden when arg provided") {
      assert(greet("World", "Hi") == "Hi, World!")
    }
  }

  fn add(a :: i64, b :: i64 = 10) -> i64 {
    a + b
  }

  fn greet(name :: String, greeting :: String = "Hello") -> String {
    greeting <> ", " <> name <> "!"
  }
}
