pub module Test.HelloWorldTest {
  use Zest.Case

  pub fn run() -> String {
    describe("greeting") {
      test("returns hello world") {
        assert(greeting() == "Hello, world!")
      }
    }

    "HelloWorldTest: passed"
  }

  fn greeting() -> String {
    "Hello, world!"
  }
}
