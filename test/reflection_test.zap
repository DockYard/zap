pub struct ReflectionTest {
  use Zest.Case
  use TestProbe

  describe("__using__ expansion") {
    test("a use target's __using__ runs even when other uses precede it") {
      assert(probe_called() == 42)
    }

    test("the use target's own functions remain callable") {
      assert(TestProbe.helper() == 1)
    }
  }
}
