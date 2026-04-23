pub struct Test.MultiStructTest {
  use Zest.Case

  describe("multi struct") {
    test("cross-struct call in comparison") {
      assert(Test.MultiStructHelper.double(5) == 10)
    }

    test("cross-struct call in string comparison") {
      assert(Test.MultiStructHelper.greet("Zap") == "Hello, Zap!")
    }

    test("stdlib qualified call in comparison") {
      assert(String.length("hello") == 5)
    }
  }
}
