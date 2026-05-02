pub struct ListBakeTest {
  use Zest.Case
  use ListBakeProbe

  describe("compile-time-baked [String] runtime accessors") {
    test("head sees first element") {
      assert(List.head(baked_list()) == "Atom")
    }

    test("length is 2") {
      assert(List.length(baked_list()) == 2)
    }

    test("contains? finds Atom") {
      assert(List.contains?(baked_list(), "Atom"))
    }

    test("contains? finds Stringable") {
      assert(List.contains?(baked_list(), "Stringable"))
    }

    test("Enum.any? matches Atom") {
      assert(Enum.any?(baked_list(), fn(name :: String) -> Bool { name == "Atom" }))
    }
  }

  describe("for-comprehension-built [String] (identity body)") {
    test("head sees first element") {
      assert(List.head(baked_list_from_for()) == "Atom")
    }

    test("length is 2") {
      assert(List.length(baked_list_from_for()) == 2)
    }

    test("contains? finds Atom") {
      assert(List.contains?(baked_list_from_for(), "Atom"))
    }
  }

  describe("for-comprehension-built [String] (transform body)") {
    test("head sees first element") {
      assert(List.head(baked_list_from_for_transform()) == "Atom")
    }

    test("length is 2") {
      assert(List.length(baked_list_from_for_transform()) == 2)
    }

    test("contains? finds Atom") {
      assert(List.contains?(baked_list_from_for_transform(), "Atom"))
    }
  }

  describe("reflection-driven [String] (source_graph_structs → struct_info → :name)") {
    test("head sees Atom") {
      assert(List.head(baked_list_from_reflection()) == "Atom")
    }

    test("length is 1") {
      assert(List.length(baked_list_from_reflection()) == 1)
    }

    test("contains? finds Atom") {
      assert(List.contains?(baked_list_from_reflection(), "Atom"))
    }
  }

  describe("Zap.Doc.Builder-shape: nested list_flatten + Path.glob") {
    test("head sees Atom") {
      assert(List.head(baked_list_from_builder_shape()) == "Atom")
    }

    test("length is 1") {
      assert(List.length(baked_list_from_builder_shape()) == 1)
    }

    test("contains? finds Atom") {
      assert(List.contains?(baked_list_from_builder_shape(), "Atom"))
    }
  }

  describe("Path.glob count probe") {
    test("Path.glob count is 1") {
      assert(baked_just_glob_count() == 1)
    }

    test("flat_refs count is 1") {
      assert(baked_flat_refs_count() == 1)
    }

    test("flat_names first resolves to Atom") {
      assert(baked_flat_names_first() == "Atom")
    }
  }
}
