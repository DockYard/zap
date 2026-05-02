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

  describe("function refs carry typed signatures per clause") {
    test("function signature renders as 'name(p :: T, ...) -> R'") {
      assert(add_signature() == "add(a :: i64, b :: i64) -> i64")
    }

    test("macro signature renders the same shape") {
      assert(twice_signature() == "twice(value :: Expr) -> Expr")
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

  describe("Protocol.required_functions enumerates required functions") {
    test("the fixture protocol declares one required function") {
      assert(protocol_required_count() == 1)
    }

    test("the required function carries its typed signature") {
      assert(protocol_required_signature() == "next(state) -> {Atom, element, any}")
    }
  }

  describe("SourceGraph.unions enumerates unions by path") {
    test("the fixture file produces exactly one union ref") {
      assert(union_count() == 1)
    }

    test("Struct.info on a union ref returns its qualified name") {
      assert(first_union_name() == "ReflectionUnion")
    }
  }

  describe("Union.variants enumerates union variants") {
    test("variant count matches the declaration") {
      assert(union_variant_count() == 3)
    }

    test("bare variant has just its name as signature") {
      assert(union_variant_first_signature() == "Up")
    }

    test("typed variant signature includes the payload type") {
      assert(union_variant_last_signature() == "Tag :: i64")
    }
  }

  describe("SourceGraph.impls returns a list shape") {
    test("a path with no impls yields an empty list") {
      assert(impl_count() == 0)
    }
  }
}
