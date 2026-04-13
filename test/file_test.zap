pub module Test.FileTest {
  use Zest.Case

  describe("File module") {
    test("exists? on missing file") {
      reject(File.exists?("_nonexistent_file_xyz.txt"))
    }

    test("read missing file returns empty") {
      assert(File.read("_nonexistent_file_xyz.txt") == "")
    }

    test("write returns true") {
      assert(File.write("_test_tmp.txt", "hello zap"))
    }

    test("exists? after write") {
      assert(File.exists?("_test_tmp.txt"))
    }

    test("read after write") {
      assert(File.read("_test_tmp.txt") == "hello zap")
    }
  }
}
