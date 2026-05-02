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

  describe("Struct.info returns struct-level metadata") {
    test("name round-trips") {
      assert(subject_name() == "ReflectionSubject")
    }

    test("source_file is the relative lib/test path") {
      assert(String.ends_with?(subject_source_file(), "reflection_subject.zap"))
    }

    test("@doc text round-trips") {
      assert(String.starts_with?(subject_doc(), "Test fixture for compile-time reflection tests."))
    }

    test("public struct reports is_private = false") {
      assert(subject_is_private() == false)
    }
  }

  describe("function refs carry source location") {
    test("source_file matches the file the function is declared in") {
      assert(String.ends_with?(add_source_file(), "reflection_subject.zap"))
    }

    test("source_line points at the function declaration") {
      assert(add_source_line() == 10)
    }

    test("macro source_line points at the macro declaration") {
      assert(twice_source_line() == 28)
    }
  }

  describe("SourceGraph.protocols enumerates protocols by path") {
    test("the fixture file produces exactly one protocol ref") {
      assert(protocol_count() == 1)
    }

    test("Struct.info on a protocol ref returns its qualified name") {
      assert(first_protocol_name() == "ReflectionProtocol")
    }
  }
}
