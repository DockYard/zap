pub module Test.DefaultParamsTest {
  use Zest

  pub fn run() -> String {
    # Integer default
    assert(add(5) == 15)
    assert(add(5, 20) == 25)

    # String default
    assert(greet("World") == "Hello, World!")
    assert(greet("World", "Hi") == "Hi, World!")

    "DefaultParamsTest: passed"
  }

  fn add(a :: i64, b :: i64 = 10) -> i64 {
    a + b
  }

  fn greet(name :: String, greeting :: String = "Hello") -> String {
    greeting <> ", " <> name <> "!"
  }
}
