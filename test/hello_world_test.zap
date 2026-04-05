pub module Test.HelloWorldTest {
  use Zest
  pub fn run() -> String {
    assert(greeting() == "Hello, world!")
    "HelloWorldTest: passed"
  }

  fn greeting() -> String {
    "Hello, world!"
  }
}
