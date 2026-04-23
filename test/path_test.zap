pub struct Test.PathTest {
  use Zest.Case

  describe("Path struct") {
    test("join two segments") {
      assert(Path.join("src", "main.zap") == "src/main.zap")
    }

    test("join with trailing slash") {
      assert(Path.join("src/", "main.zap") == "src/main.zap")
    }

    test("join empty left") {
      assert(Path.join("", "main.zap") == "main.zap")
    }

    test("join empty right") {
      assert(Path.join("src", "") == "src")
    }

    test("basename from path") {
      assert(Path.basename("/usr/bin/zap") == "zap")
    }

    test("basename without directory") {
      assert(Path.basename("main.zap") == "main.zap")
    }

    test("dirname from path") {
      assert(Path.dirname("/usr/bin/zap") == "/usr/bin")
    }

    test("dirname without directory") {
      assert(Path.dirname("main.zap") == ".")
    }

    test("dirname root path") {
      assert(Path.dirname("/zap") == "/")
    }

    test("extname with extension") {
      assert(Path.extname("main.zap") == ".zap")
    }

    test("extname without extension") {
      assert(Path.extname("Makefile") == "")
    }

    test("extname nested path") {
      assert(Path.extname("src/main.zap") == ".zap")
    }
  }
}
