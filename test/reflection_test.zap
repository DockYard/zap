pub struct ReflectionTest {
  use Zest.Case
  use TestProbe

  describe("Struct.functions returns @doc text") {
    test("single-line doc round-trips") {
      assert(add_doc() == "Adds two integers.")
    }

    test("heredoc doc round-trips with indent stripped") {
      assert(String.starts_with?(multiply_doc(), "Multiplies two integers."))
    }

    test("undocumented function surfaces empty string") {
      assert(no_doc_doc() == "")
    }
  }
}
