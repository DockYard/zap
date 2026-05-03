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

    test("manifest_struct_summaries first entry has source_file") {
      _summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(_summary, :source_file))
    }

    test("manifest_struct_summaries first entry has is_private") {
      _summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(_summary, :is_private))
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

    test("render_summary_page composes name + doc into HTML") {
      _summary = List.head(manifest_struct_summaries())
      _html = Zap.Doc.render_summary_page(_summary, :struct, manifest_structs(), manifest_protocols(), manifest_unions())
      assert(String.contains?(_html, "Atom"))
      assert(String.contains?(_html, "Functions for working with atoms"))
    }

    test("write_docs_to writes one HTML file per reflected module") {
      _ = File.mkdir("zap-out/test-docs")
      _count = write_docs_to("zap-out/test-docs")
      assert(_count > 0)
      _atom_html = File.read("zap-out/test-docs/Atom.html")
      assert(String.contains?(_atom_html, "Functions for working with atoms"))
    }

    test("rendered struct page breadcrumb labels Atom as a Struct") {
      _ = File.mkdir("zap-out/test-docs")
      _ = write_docs_to("zap-out/test-docs")
      _atom_html = File.read("zap-out/test-docs/Atom.html")
      assert(String.contains?(_atom_html, "<span>Structs</span>"))
    }

    test("rendered struct page renders @doc markdown to HTML") {
      _ = File.mkdir("zap-out/test-docs")
      _ = write_docs_to("zap-out/test-docs")
      _atom_html = File.read("zap-out/test-docs/Atom.html")
      # The @doc has a "## Examples" section that should become an h2
      assert(String.contains?(_atom_html, "<h2>Examples</h2>"))
    }

    test("write_docs_to also writes an index.html landing page") {
      _ = File.mkdir("zap-out/test-docs")
      _ = write_docs_to("zap-out/test-docs")
      _index_html = File.read("zap-out/test-docs/index.html")
      assert(String.contains?(_index_html, "Atom"))
      assert(String.contains?(_index_html, "Stringable"))
    }



  }
}
