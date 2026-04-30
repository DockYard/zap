pub struct Test.ImportTest {
  use Zest.Case
  import Test.MultiStructHelper

  describe("imports") {
    test("imported double function works") {
      assert(double(3) == 6)
    }

    test("imported greet function works") {
      assert(greet("World") == "Hello, World!")
    }
  }
}
