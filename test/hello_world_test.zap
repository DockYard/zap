pub module Test.HelloWorldTest {
  use Zest.Case

  describe("greeting") {
    test("returns hello world") {
      assert(greeting() == "Hello, world!")
    }
  }

  fn greeting() -> String {
    "Hello, world!"
  }
}
