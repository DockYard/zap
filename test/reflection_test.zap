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

  describe("Struct.macros enumerates only macros") {
    test("macro doc round-trips") {
      assert(twice_doc() == "Doubles its argument at compile time.")
    }

    test("functions list excludes macros") {
      assert(function_count() == 3)
    }

    test("macros list excludes functions") {
      assert(macro_count() == 1)
    }
  }
}
