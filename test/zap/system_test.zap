pub struct Zap.SystemTest {
  use Zest.Case

  describe("System struct") {
    test("cwd returns non-empty string") {
      assert(String.length(System.cwd()) > 0)
    }

    test("get_env HOME") {
      assert(String.length(System.get_env("HOME")) > 0)
    }

    test("get_env missing returns empty") {
      assert(System.get_env("_ZAP_NONEXISTENT_VAR_") == "")
    }
  }
}
