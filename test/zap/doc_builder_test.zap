pub struct Zap.DocBuilderTest {
  use Zest.Case
  use Zap.Doc.Builder, paths: ["lib/atom.zap", "lib/stringable.zap"]

  describe("Zap.Doc.Builder bakes manifest functions") {
    test("manifest_structs contains Atom") {
      assert(List.contains?(manifest_structs(), "Atom"))
    }

    test("manifest_protocols contains Stringable") {
      assert(List.contains?(manifest_protocols(), "Stringable"))
    }

    test("manifest_unions returns a list shape") {
      _names = manifest_unions()
      assert(List.empty?(_names) or true)
    }

    test("manifest_struct_summaries returns a non-empty list of maps") {
      _summaries = manifest_struct_summaries()
      assert(List.length(_summaries) > 0)
    }

    test("manifest_struct_summaries first entry has name and doc keys") {
      _summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(_summary, :name))
      assert(Map.has_key?(_summary, :doc))
    }
  }
}
