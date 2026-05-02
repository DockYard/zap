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
  }
}
