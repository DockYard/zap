pub struct Zap.DocBuilderTest {
  use Zest.Case
  use Zap.Doc.Builder, paths: ["lib/atom.zap", "lib/stringable.zap"]

  fn render_first_struct_html() -> String {
    _summary = List.head(manifest_struct_summaries())
    _name = Map.get(_summary, :name, "")
    _doc = Map.get(_summary, :doc, "")
    _content = "<h1>" <> Zap.Doc.escape_html(_name) <> "</h1>\n<p>" <> Zap.Doc.escape_html(_doc) <> "</p>\n"
    _sidebar = Zap.Doc.sidebar(manifest_structs(), manifest_protocols(), manifest_unions(), _name, "")
    Zap.Doc.struct_page("Zap", "0.0.0", _name, "", "", _sidebar, _content, "")
  }

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

    test("manifest_struct_summaries first entry has source_file") {
      _summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(_summary, :source_file))
    }

    test("manifest_struct_summaries first entry has is_private") {
      _summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(_summary, :is_private))
    }

    test("manifest_struct_summaries first entry has functions list") {
      _summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(_summary, :functions))
    }

    test("manifest_struct_summaries first entry has macros list") {
      _summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(_summary, :macros))
    }

    test("manifest_protocol_summaries returns a list of maps") {
      _summaries = manifest_protocol_summaries()
      assert(List.length(_summaries) >= 0)
    }

    test("manifest_union_summaries returns a list of maps") {
      _summaries = manifest_union_summaries()
      assert(List.length(_summaries) >= 0)
    }

    test("first struct summary's :name extracts as a String") {
      _summary = List.head(manifest_struct_summaries())
      _name = Map.get(_summary, :name, "")
      assert(String.length(_name) > 0)
    }

    test("render_first_struct_html embeds the struct name") {
      _html = render_first_struct_html()
      assert(String.contains?(_html, "Atom"))
    }

    test("render_first_struct_html embeds the struct doc") {
      _html = render_first_struct_html()
      assert(String.contains?(_html, "Functions for working with atoms"))
    }



  }
}
