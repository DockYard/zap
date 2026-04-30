pub struct Zap.PathTest {
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

    test("glob returns sorted matching paths") {
      File.rm("_path_glob_fixture/a.zap")
      File.rm("_path_glob_fixture/b.zap")
      File.rmdir("_path_glob_fixture")

      assert(File.mkdir("_path_glob_fixture"))
      assert(File.write("_path_glob_fixture/b.zap", "b"))
      assert(File.write("_path_glob_fixture/a.zap", "a"))

      matches = Path.glob("_path_glob_fixture/*.zap")

      assert(List.length(matches) == 2)
      assert(List.at(matches, 0) == "_path_glob_fixture/a.zap")
      assert(List.at(matches, 1) == "_path_glob_fixture/b.zap")

      File.rm("_path_glob_fixture/a.zap")
      File.rm("_path_glob_fixture/b.zap")
      File.rmdir("_path_glob_fixture")
    }

    test("glob supports recursive double star") {
      File.rm("_path_glob_recursive/lib/nested/b.zap")
      File.rm("_path_glob_recursive/lib/a.zap")
      File.rmdir("_path_glob_recursive/lib/nested")
      File.rmdir("_path_glob_recursive/lib")
      File.rmdir("_path_glob_recursive")

      assert(File.mkdir("_path_glob_recursive"))
      assert(File.mkdir("_path_glob_recursive/lib"))
      assert(File.mkdir("_path_glob_recursive/lib/nested"))
      assert(File.write("_path_glob_recursive/lib/a.zap", "a"))
      assert(File.write("_path_glob_recursive/lib/nested/b.zap", "b"))

      matches = Path.glob("_path_glob_recursive/lib/**/*.zap")

      assert(List.length(matches) == 2)
      assert(List.at(matches, 0) == "_path_glob_recursive/lib/a.zap")
      assert(List.at(matches, 1) == "_path_glob_recursive/lib/nested/b.zap")

      File.rm("_path_glob_recursive/lib/nested/b.zap")
      File.rm("_path_glob_recursive/lib/a.zap")
      File.rmdir("_path_glob_recursive/lib/nested")
      File.rmdir("_path_glob_recursive/lib")
      File.rmdir("_path_glob_recursive")
    }

    test("glob returns empty list for no matches") {
      matches = Path.glob("_path_glob_missing/**/*.zap")

      assert(List.empty?(matches))
    }
  }
}
