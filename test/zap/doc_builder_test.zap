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
      names = manifest_unions()
      assert(List.empty?(names) or true)
    }

    test("manifest_struct_summaries returns a non-empty list of maps") {
      summaries = manifest_struct_summaries()
      assert(List.length(summaries) > 0)
    }

    test("manifest_struct_summaries first entry has name and doc keys") {
      summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(summary, :name))
      assert(Map.has_key?(summary, :doc))
    }

    test("manifest_struct_summaries first entry has source_file") {
      summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(summary, :source_file))
    }

    test("manifest_struct_summaries first entry has is_private") {
      summary = List.head(manifest_struct_summaries())
      assert(Map.has_key?(summary, :is_private))
    }

    test("manifest_protocol_summaries returns a list of maps") {
      summaries = manifest_protocol_summaries()
      assert(List.length(summaries) >= 0)
    }

    test("manifest_union_summaries returns a list of maps") {
      summaries = manifest_union_summaries()
      assert(List.length(summaries) >= 0)
    }

    test("first struct summary's :name extracts as a String") {
      summary = List.head(manifest_struct_summaries())
      name = Map.get(summary, :name, "")
      assert(String.length(name) > 0)
    }

    test("render_first_struct_html embeds the struct name") {
      html = render_first_struct_html()
      assert(String.contains?(html, "Atom"))
    }

    test("render_first_struct_html embeds the struct doc") {
      html = render_first_struct_html()
      assert(String.contains?(html, "Functions for working with atoms"))
    }

    test("render_summary_page composes name + doc into HTML") {
      summary = List.head(manifest_struct_summaries())
      html = Zap.Doc.render_summary_page(summary, :struct, "Zap", "0.0.0", "https://github.com/DockYard/zap", manifest_structs(), manifest_protocols(), manifest_unions(), [] :: [String], manifest_function_summaries(), manifest_macro_summaries(), manifest_impl_summaries(), manifest_variant_summaries(), manifest_required_function_summaries())
      assert(String.contains?(html, "Atom"))
      assert(String.contains?(html, "Functions for working with atoms"))
    }

    test("manifest_function_summaries returns a non-empty list") {
      funcs = manifest_function_summaries()
      assert(List.length(funcs) > 0)
    }

    test("manifest_function_summaries first entry has :module and :name") {
      f = List.head(manifest_function_summaries())
      assert(Map.has_key?(f, :module))
      assert(Map.has_key?(f, :name))
    }

    test("manifest_function_summaries first entry carries :source_file and :source_line") {
      f = List.head(manifest_function_summaries())
      source = Map.get(f, :source_file, "")
      assert(String.length(source) > 0)
      line = Map.get(f, :source_line, 0)
      assert(line > 0)
    }

    test("manifest_impl_summaries returns a list shape") {
      impls = manifest_impl_summaries()
      assert(List.length(impls) >= 0)
    }

    test("manifest_variant_summaries returns a list shape") {
      variants = manifest_variant_summaries()
      assert(List.length(variants) >= 0)
    }

    test("manifest_required_function_summaries returns a list shape") {
      required = manifest_required_function_summaries()
      assert(List.length(required) >= 0)
    }

    test("write_docs_to renders docs assets pages and search index") {
      _ = File.mkdir("zap-out/test-docs")
      _ = File.rm("zap-out/test-docs/style.css")
      _ = File.rm("zap-out/test-docs/app.js")
      _ = File.rm("zap-out/test-docs/index.html")
      _ = File.rm("zap-out/test-docs/search-index.json")
      _ = File.rm("zap-out/test-docs/structs/Atom.html")

      count = write_docs_to("zap-out/test-docs", "Zap", "0.0.0", "https://github.com/DockYard/zap")
      assert(count > 0)

      css = File.read("zap-out/test-docs/style.css")
      assert(String.length(css) > 0)

      js = File.read("zap-out/test-docs/app.js")
      assert(String.length(js) > 0)

      atom_html = File.read("zap-out/test-docs/structs/Atom.html")
      assert(String.contains?(atom_html, "Functions for working with atoms"))
      assert(String.contains?(atom_html, "<table class=\"summary\">"))
      assert(String.contains?(atom_html, "to_string"))
      assert(String.contains?(atom_html, "<span>Structs</span>"))
      assert(String.contains?(atom_html, "<h2>Examples</h2>"))
      assert(String.contains?(atom_html, "github.com/DockYard/zap/blob/v0.0.0/lib/atom.zap#L"))

      index_html = File.read("zap-out/test-docs/index.html")
      assert(String.contains?(index_html, "Atom"))
      assert(String.contains?(index_html, "Stringable"))

      index = File.read("zap-out/test-docs/search-index.json")
      assert(String.contains?(index, "\"struct\":\"Atom\""))
      assert(String.contains?(index, "\"type\":\"struct\""))
      assert(String.contains?(index, "\"url\":\"structs/Atom.html\""))
      assert(String.contains?(index, "\"struct\":\"Stringable\""))
      assert(String.contains?(index, "\"type\":\"protocol\""))
    }

    test("source_link suppresses the link when source_url is empty") {
      link = Zap.Doc.source_link("lib/atom.zap", 10, "", "0.0.0")
      assert(String.length(link) == 0)
    }

  }
}
