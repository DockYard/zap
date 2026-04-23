pub struct Test.FileTest {
  use Zest.Case

  describe("File struct") {
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

    test("read! returns content for existing file") {
      assert(File.read!("_test_tmp.txt") == "hello zap")
    }

    test("rm deletes file") {
      File.write("_test_rm.txt", "delete me")
      assert(File.exists?("_test_rm.txt"))
      assert(File.rm("_test_rm.txt"))
      reject(File.exists?("_test_rm.txt"))
    }

    test("rename moves file") {
      File.write("_test_rename_src.txt", "move me")
      assert(File.rename("_test_rename_src.txt", "_test_rename_dst.txt"))
      reject(File.exists?("_test_rename_src.txt"))
      assert(File.read("_test_rename_dst.txt") == "move me")
      File.rm("_test_rename_dst.txt")
    }

    test("cp copies file") {
      File.write("_test_cp_src.txt", "copy me")
      assert(File.cp("_test_cp_src.txt", "_test_cp_dst.txt"))
      assert(File.read("_test_cp_dst.txt") == "copy me")
      File.rm("_test_cp_src.txt")
      File.rm("_test_cp_dst.txt")
    }

    test("mkdir and rmdir") {
      assert(File.mkdir("_test_dir"))
      assert(File.dir?("_test_dir"))
      assert(File.rmdir("_test_dir"))
      reject(File.exists?("_test_dir"))
    }

    test("regular? on file") {
      assert(File.regular?("_test_tmp.txt"))
    }

    test("dir? on file is false") {
      reject(File.dir?("_test_tmp.txt"))
    }
  }
}
