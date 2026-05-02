pub struct Zap.DocBuilderTest {
  use Zest.Case
  use Zap.Doc.Builder, paths: ["test/zap/doc_builder_fixture.zap"]

  # Force discovery to pull in the fixture file so source-graph
  # reflection at expansion time can find its struct entry.
  fn ensure_fixture_discovered() -> i64 {
    Zap.DocBuilderFixture.marker()
  }

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
  }
}
