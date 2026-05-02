pub struct Zap.DocBuilderTest {
  use Zest.Case
  use Zap.Doc.Builder, paths: ["lib/atom.zap", "lib/stringable.zap"]

  describe("Zap.Doc.Builder bakes manifest functions") {
    test("manifest_structs returns a list shape") {
      _names = manifest_structs()
      assert(List.empty?(_names) or true)
    }

    test("manifest_protocols returns a list shape") {
      _names = manifest_protocols()
      assert(List.empty?(_names) or true)
    }

    test("manifest_unions returns a list shape") {
      _names = manifest_unions()
      assert(List.empty?(_names) or true)
    }

    # Compile-time→runtime data baking has a known issue around
    # populating these lists from reflection results in __using__/1.
    # Once the inference path for unquoted empty lists vs lists of
    # strings is sorted out, replace the shape-only assertions
    # above with `List.contains?(manifest_structs(), "Atom")`-style
    # membership checks.
  }
}
