pub struct Zap.FileTest {
  use Zest.Case

  describe("File struct") {
    test("exists? on missing file") {
      reject(File.exists?("_nonexistent_file_xyz.txt"))
    }

    test("read missing file returns empty") {
      assert(File.read("_nonexistent_file_xyz.txt") == "")
    }

    test("write returns true") {
      assert(File.write("_test_write.txt", "hello zap"))
      File.rm("_test_write.txt")
    }

    test("exists? after write") {
      File.write("_test_exists.txt", "hello zap")
      assert(File.exists?("_test_exists.txt"))
      File.rm("_test_exists.txt")
    }

    test("read after write") {
      File.write("_test_read.txt", "hello zap")
      assert(File.read("_test_read.txt") == "hello zap")
      File.rm("_test_read.txt")
    }

    test("read! returns content for existing file") {
      File.write("_test_read_bang.txt", "hello zap")
      assert(File.read!("_test_read_bang.txt") == "hello zap")
      File.rm("_test_read_bang.txt")
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

    test("read returns entire contents of a file larger than 1 MiB") {
      # Build 2,000,000 bytes of known content with a distinct tail marker
      # that lives well past the historical 1 MiB (1,048,576-byte) cap, so
      # any truncation is detectable by both length and content.
      body = String.repeat("ab", 1_000_000)
      content = body <> "ZAP_TAIL_MARKER"
      assert(File.write("_test_large_read.txt", content))
      read_back = File.read("_test_large_read.txt")
      assert(String.length(read_back) == 2_000_015)
      assert(read_back == content)
      assert(String.ends_with?(read_back, "ZAP_TAIL_MARKER"))
      File.rm("_test_large_read.txt")
    }

    test("cp produces a byte-identical copy of a file larger than 1 MiB") {
      body = String.repeat("xy", 1_000_000)
      content = body <> "CP_TAIL_MARKER"
      assert(File.write("_test_large_cp_src.txt", content))
      assert(File.cp("_test_large_cp_src.txt", "_test_large_cp_dst.txt"))
      copy = File.read("_test_large_cp_dst.txt")
      assert(String.length(copy) == 2_000_014)
      assert(copy == content)
      assert(String.ends_with?(copy, "CP_TAIL_MARKER"))
      File.rm("_test_large_cp_src.txt")
      File.rm("_test_large_cp_dst.txt")
    }

    test("read and cp round-trip a small file exactly (control)") {
      assert(File.write("_test_small_rt.txt", "small control content"))
      assert(File.read("_test_small_rt.txt") == "small control content")
      assert(File.cp("_test_small_rt.txt", "_test_small_rt_dst.txt"))
      assert(File.read("_test_small_rt_dst.txt") == "small control content")
      File.rm("_test_small_rt.txt")
      File.rm("_test_small_rt_dst.txt")
    }

    test("cp of an empty source creates an empty destination and succeeds") {
      assert(File.write("_test_empty_src.txt", ""))
      assert(File.cp("_test_empty_src.txt", "_test_empty_dst.txt"))
      assert(File.exists?("_test_empty_dst.txt"))
      assert(File.read("_test_empty_dst.txt") == "")
      File.rm("_test_empty_src.txt")
      File.rm("_test_empty_dst.txt")
    }

    test("mkdir and rmdir") {
      assert(File.mkdir("_test_dir"))
      assert(File.dir?("_test_dir"))
      assert(File.rmdir("_test_dir"))
      reject(File.exists?("_test_dir"))
    }

    test("regular? on file") {
      File.write("_test_regular.txt", "hello zap")
      assert(File.regular?("_test_regular.txt"))
      File.rm("_test_regular.txt")
    }

    test("dir? on file is false") {
      File.write("_test_dir_check.txt", "hello zap")
      reject(File.dir?("_test_dir_check.txt"))
      File.rm("_test_dir_check.txt")
    }
  }
}
