pub struct Zap.DocTest {
  use Zest.Case

  fn empty_string_list() -> [String] {
    List.tail(["sentinel"])
  }

  describe("Zap.Doc.page_title") {
    test("renders an h1 with the module name") {
      assert(Zap.Doc.page_title("Enum") == "<h1 class=\"page-title\">Enum</h1>\n")
    }

    test("escapes HTML in the name") {
      assert(Zap.Doc.page_title("<bad>") == "<h1 class=\"page-title\">&lt;bad&gt;</h1>\n")
    }
  }

  describe("Zap.Doc.escape_html") {
    test("ampersand escapes") {
      assert(Zap.Doc.escape_html("Tom & Jerry") == "Tom &amp; Jerry")
    }

    test("less-than and greater-than escape") {
      assert(Zap.Doc.escape_html("<a>") == "&lt;a&gt;")
    }

    test("double-quote escapes") {
      assert(Zap.Doc.escape_html("say \"hi\"") == "say &quot;hi&quot;")
    }

    test("plain text passes through unchanged") {
      assert(Zap.Doc.escape_html("hello") == "hello")
    }

    test("empty string round-trips") {
      assert(Zap.Doc.escape_html("") == "")
    }
  }

  describe("Zap.Doc.breadcrumb") {
    test("struct breadcrumb names the Structs category") {
      expected = "<nav class=\"breadcrumb\" aria-label=\"Breadcrumb\">\n<span>Structs</span>\n<span>/</span>\n<span class=\"breadcrumb-current\">Enum</span>\n</nav>\n"
      assert(Zap.Doc.breadcrumb(:struct, "Enum") == expected)
    }

    test("protocol breadcrumb names the Protocols category") {
      assert(String.contains?(Zap.Doc.breadcrumb(:protocol, "Enumerable"), "<span>Protocols</span>"))
    }

    test("union breadcrumb names the Unions category") {
      assert(String.contains?(Zap.Doc.breadcrumb(:union, "IO.Mode"), "<span>Unions</span>"))
    }

    test("breadcrumb HTML-escapes the current name") {
      assert(String.contains?(Zap.Doc.breadcrumb(:struct, "<script>"), "&lt;script&gt;"))
    }
  }

  describe("Zap.Doc.tagline") {
    test("empty input renders nothing") {
      assert(Zap.Doc.tagline("") == "")
    }

    test("non-empty input wraps in p.tagline") {
      assert(Zap.Doc.tagline("A range of integers.") == "<p class=\"tagline\">A range of integers.</p>\n")
    }

    test("tagline HTML-escapes its input") {
      assert(Zap.Doc.tagline("a < b") == "<p class=\"tagline\">a &lt; b</p>\n")
    }
  }

  describe("Zap.Doc.implements_link") {
    test("renders one accent-bordered link") {
      assert(Zap.Doc.implements_link("Arithmetic") == "<a class=\"implements-link\" href=\"../structs/Arithmetic.html\">Arithmetic</a>\n")
    }

    test("HTML-escapes the protocol name") {
      assert(String.contains?(Zap.Doc.implements_link("<bad>"), "&lt;bad&gt;"))
    }
  }

  describe("Zap.Doc.summary_row") {
    test("renders name/arity link cell and doc cell") {
      result = Zap.Doc.summary_row("map", 2, "Transforms each element.")
      assert(String.contains?(result, "<tr><td class=\"summary-name\"><a href=\"#map-2\">map/2</a></td>"))
      assert(String.contains?(result, "<td class=\"summary-doc\">Transforms each element.</td>"))
    }

    test("HTML-escapes the summary text") {
      result = Zap.Doc.summary_row("danger", 0, "use < not &")
      assert(String.contains?(result, "use &lt; not &amp;"))
    }
  }

  describe("Zap.Doc.signature_block") {
    test("wraps the signature in a code panel") {
      assert(Zap.Doc.signature_block("map(value :: i64) -> i64") == "<div class=\"signature\"><code>map(value :: i64) -&gt; i64</code></div>\n")
    }
  }

  describe("Zap.Doc.sidebar_item") {
    test("inactive item renders without active class") {
      assert(Zap.Doc.sidebar_item("Atom", false, "../") == "<li><a href=\"../structs/Atom.html\">Atom</a></li>\n")
    }

    test("active item gets the active class") {
      assert(Zap.Doc.sidebar_item("Enum", true, "../") == "<li class=\"active\"><a href=\"../structs/Enum.html\">Enum</a></li>\n")
    }

    test("base prefix is preserved in the href") {
      assert(String.contains?(Zap.Doc.sidebar_item("Atom", false, ""), "href=\"structs/Atom.html\""))
    }
  }

  describe("Zap.Doc.sidebar_group") {
    test("renders chevron button and one item per member") {
      result = Zap.Doc.sidebar_group("Structs", ["Atom", "Bool", "Enum"], "Bool", "../")
      assert(String.contains?(result, "data-group=\"Structs\""))
      assert(String.contains?(result, "<button class=\"sidebar-group-header\""))
      assert(String.contains?(result, "<h4>Structs</h4>"))
      assert(String.contains?(result, "<li><a href=\"../structs/Atom.html\">Atom</a></li>"))
      assert(String.contains?(result, "<li class=\"active\"><a href=\"../structs/Bool.html\">Bool</a></li>"))
      assert(String.contains?(result, "<li><a href=\"../structs/Enum.html\">Enum</a></li>"))
    }

    test("empty current name leaves all items inactive") {
      result = Zap.Doc.sidebar_group("Structs", ["Atom"], "", "../")
      assert(String.contains?(result, "<li><a"))
      assert(String.contains?(result, "class=\"active\"") == false)
    }
  }

  describe("Zap.Doc.summary_table") {
    test("empty rows body renders nothing") {
      assert(Zap.Doc.summary_table("Functions", "functions", "") == "")
    }

    test("non-empty rows wrap in heading and table") {
      row = Zap.Doc.summary_row("map", 2, "Transforms each element.")
      result = Zap.Doc.summary_table("Functions", "functions", row)
      assert(String.starts_with?(result, "<h2 id=\"functions\">Functions</h2>"))
      assert(String.contains?(result, "<table class=\"summary\">"))
      assert(String.contains?(result, "<a href=\"#map-2\">map/2</a>"))
      assert(String.ends_with?(result, "</table>\n"))
    }
  }

  describe("Zap.Doc.first_sentence") {
    test("trims at the first period followed by space") {
      assert(Zap.Doc.first_sentence("First. Second.") == "First.")
    }

    test("returns whole text when no period exists") {
      assert(Zap.Doc.first_sentence("no period here") == "no period here")
    }

    test("empty input returns empty") {
      assert(Zap.Doc.first_sentence("") == "")
    }

    test("period followed by newline counts as boundary") {
      assert(Zap.Doc.first_sentence("Line one.\nLine two.") == "Line one.")
    }
  }

  describe("Zap.Doc.render_summary_rows") {
    test("empty list renders nothing") {
      empty = List.tail([{"sentinel", 0, ""}])
      assert(Zap.Doc.render_summary_rows(empty, "") == "")
    }

    test("multi-element list renders one row per entry") {
      items = [{"map", 2, "Transforms each element."}, {"filter", 2, "Keeps matching elements."}]
      result = Zap.Doc.render_summary_rows(items, "")
      assert(String.contains?(result, "<a href=\"#map-2\">map/2</a>"))
      assert(String.contains?(result, "<a href=\"#filter-2\">filter/2</a>"))
      assert(String.contains?(result, "Transforms each element."))
    }
  }

  describe("Zap.Doc.module_main_content") {
    test("composes breadcrumb, title, implements, tagline, structdoc, sections in order") {
      result = Zap.Doc.module_main_content(:struct, "Enum", ["Enumerable"], "A range of integers.", "<p>body</p>\n", "<tr><td>row</td></tr>\n", "", "<div class=\"function-detail\" id=\"map-2\">d</div>\n", "")
      assert(String.contains?(result, "<span class=\"breadcrumb-current\">Enum</span>"))
      assert(String.contains?(result, "<h1 class=\"page-title\">Enum</h1>"))
      assert(String.contains?(result, "<a class=\"implements-link\" href=\"../structs/Enumerable.html\">"))
      assert(String.contains?(result, "<p class=\"tagline\">A range of integers.</p>"))
      assert(String.contains?(result, "<div class=\"structdoc\">\n<p>body</p>"))
      assert(String.contains?(result, "<h2 id=\"functions\">Functions</h2>"))
      assert(String.contains?(result, "<h2>Function Details</h2>"))
    }

    test("empty structdoc/macros/details collapse cleanly") {
      result = Zap.Doc.module_main_content(:struct, "Empty", empty_string_list(), "", "", "", "", "", "")
      assert(String.contains?(result, "<h1 class=\"page-title\">Empty</h1>"))
      assert(String.contains?(result, "implements-link") == false)
      assert(String.contains?(result, "structdoc") == false)
      assert(String.contains?(result, "<h2") == false)
    }
  }

  describe("Zap.Doc.struct_page") {
    test("wraps chrome around composed sidebar / main / rail") {
      result = Zap.Doc.struct_page("zap_stdlib", "0.1.0", "Enum", "../", "", "<nav class=\"sidebar\">S</nav>", "main", "<aside class=\"toc\">R</aside>")
      assert(String.starts_with?(result, "<!DOCTYPE html>"))
      assert(String.contains?(result, "<title>Enum"))
      assert(String.contains?(result, "<header class=\"topbar\">"))
      assert(String.contains?(result, "<nav class=\"sidebar\">S</nav>"))
      assert(String.contains?(result, "<main class=\"content\">\nmain</main>"))
      assert(String.contains?(result, "<aside class=\"toc\">R</aside>"))
      assert(String.contains?(result, "<script src=\"../app.js\">"))
      assert(String.ends_with?(result, "</body>\n</html>\n"))
    }
  }

  describe("Zap.Doc.layout") {
    test("with right rail uses the three-column layout") {
      result = Zap.Doc.layout("<nav>S</nav>", "body", "<aside>R</aside>")
      assert(String.starts_with?(result, "<div class=\"layout\">"))
      assert(String.contains?(result, "<nav>S</nav>"))
      assert(String.contains?(result, "<main class=\"content\">\nbody</main>"))
      assert(String.contains?(result, "<aside>R</aside>"))
    }

    test("without right rail uses the two-column layout") {
      result = Zap.Doc.layout("<nav>S</nav>", "body", "")
      assert(String.starts_with?(result, "<div class=\"layout layout-no-toc\">"))
      assert(String.contains?(result, "<aside") == false)
    }
  }

  describe("Zap.Doc.sidebar") {
    test("renders one group per non-empty member list") {
      result = Zap.Doc.sidebar(["Atom", "Bool"], ["Stringable"], empty_string_list(), empty_string_list(), "Bool", "../", "zap_stdlib", "0.1.0")
      assert(String.starts_with?(result, "<nav class=\"sidebar\">"))
      assert(String.contains?(result, "<h4>Structs</h4>"))
      assert(String.contains?(result, "<h4>Protocols</h4>"))
      assert(String.contains?(result, "<h4>Unions</h4>") == false)
      assert(String.contains?(result, "<li class=\"active\"><a href=\"../structs/Bool.html\">Bool</a></li>"))
      assert(String.contains?(result, "class=\"sidebar-title\">zap_stdlib</a>"))
      assert(String.contains?(result, "class=\"sidebar-version\">v0.1.0</span>"))
    }

    test("empty groups produce a sidebar with only the search header") {
      empty = empty_string_list()
      result = Zap.Doc.sidebar(empty, empty, empty, empty, "", "", "zap_stdlib", "0.1.0")
      assert(String.contains?(result, "<h4>") == false)
      assert(String.contains?(result, "<div class=\"sidebar-search\">"))
    }
  }

  describe("Zap.Doc.topbar") {
    test("renders brand, search trigger, theme toggle, github link") {
      result = Zap.Doc.topbar("zap_stdlib", "0.1.0", "../", "https://github.com/DockYard/zap")
      assert(String.starts_with?(result, "<header class=\"topbar\">"))
      assert(String.contains?(result, "<a href=\"../index.html\" class=\"topbar-title\">zap_stdlib</a>"))
      assert(String.contains?(result, "<span class=\"topbar-version\">v0.1.0</span>"))
      assert(String.contains?(result, "id=\"search-trigger\""))
      assert(String.contains?(result, "id=\"theme-toggle\""))
      assert(String.contains?(result, "href=\"https://github.com/DockYard/zap\""))
    }

    test("empty source_url omits the github link") {
      result = Zap.Doc.topbar("name", "0.0.0", "", "")
      assert(String.contains?(result, "topbar-github") == false)
    }
  }

  describe("Zap.Doc.page_open") {
    test("renders doctype, head, and body open") {
      result = Zap.Doc.page_open("Enum", "zap_stdlib", "../")
      assert(String.starts_with?(result, "<!DOCTYPE html>"))
      assert(String.contains?(result, "<title>Enum"))
      assert(String.contains?(result, "<link rel=\"stylesheet\" href=\"../style.css\">"))
      assert(String.contains?(result, "<meta name=\"zap-docs-base\" content=\"../\">"))
      assert(String.ends_with?(result, "</head>\n<body>\n"))
    }
  }

  describe("Zap.Doc.page_close") {
    test("renders search modal and closing script") {
      result = Zap.Doc.page_close("../")
      assert(String.contains?(result, "id=\"search-modal\""))
      assert(String.contains?(result, "<script src=\"../app.js\">"))
      assert(String.ends_with?(result, "</body>\n</html>\n"))
    }
  }

  describe("Zap.Doc.toc_item") {
    test("renders an in-page anchor list item") {
      assert(Zap.Doc.toc_item("map", 2) == "<li><a href=\"#map-2\">map/2</a></li>\n")
    }
  }

  describe("Zap.Doc.toc_section_label") {
    test("renders the section divider li") {
      assert(Zap.Doc.toc_section_label("Functions") == "<li class=\"toc-section\">Functions</li>\n")
    }
  }

  describe("Zap.Doc.right_rail") {
    test("empty items renders no rail") {
      assert(Zap.Doc.right_rail("") == "")
    }

    test("non-empty items wrap in aside.toc") {
      items = Zap.Doc.toc_item("map", 2)
      result = Zap.Doc.right_rail(items)
      assert(String.starts_with?(result, "<aside class=\"toc\">"))
      assert(String.contains?(result, "<h3>On This Page</h3>"))
      assert(String.contains?(result, "<li><a href=\"#map-2\">map/2</a></li>"))
      assert(String.ends_with?(result, "</aside>\n"))
    }
  }

  describe("Zap.Doc.function_details_section") {
    test("empty body renders nothing") {
      assert(Zap.Doc.function_details_section("Function Details", "") == "")
    }

    test("non-empty body wraps in heading") {
      block = Zap.Doc.function_detail("map", 2, false, ["map(x :: i64) -> i64"], "<p>Transforms.</p>\n")
      result = Zap.Doc.function_details_section("Function Details", block)
      assert(String.starts_with?(result, "<h2>Function Details</h2>"))
      assert(String.contains?(result, "<div class=\"function-detail\" id=\"map-2\">"))
    }
  }

  describe("Zap.Doc.function_detail") {
    test("composes id, header, signature, and rendered doc") {
      result = Zap.Doc.function_detail("map", 2, false, ["map(value :: i64) -> i64"], "<p>Transforms each element.</p>\n")
      assert(String.starts_with?(result, "<div class=\"function-detail\" id=\"map-2\">"))
      assert(String.contains?(result, "<span class=\"badge\">fn</span>"))
      assert(String.contains?(result, "<div class=\"signature\">"))
      assert(String.contains?(result, "<div class=\"function-doc\">\n<p>Transforms each element.</p>\n</div>"))
      assert(String.ends_with?(result, "</div>\n"))
    }

    test("multi-clause functions get multiple signature panels") {
      result = Zap.Doc.function_detail("classify", 1, false, ["classify(0 :: i64) -> String", "classify(value :: i64) -> String"], "")
      assert(String.contains?(result, "0 :: i64"))
      assert(String.contains?(result, "value :: i64"))
    }

    test("undocumented functions omit the doc div") {
      result = Zap.Doc.function_detail("noop", 0, false, ["noop() -> Atom"], "")
      assert(String.contains?(result, "function-doc") == false)
    }
  }

  describe("Zap.Doc.anchor_id") {
    test("name and arity join with a dash") {
      assert(Zap.Doc.anchor_id("map", 2) == "map-2")
    }

    test("zero-arity functions still get an arity suffix") {
      assert(Zap.Doc.anchor_id("run", 0) == "run-0")
    }
  }

  describe("Zap.Doc.function_header") {
    test("public function gets an fn badge and anchor link") {
      result = Zap.Doc.function_header("map", 2, false)
      assert(String.contains?(result, "<h3>map<span class=\"arity\">/2</span></h3>"))
      assert(String.contains?(result, "<span class=\"badge\">fn</span>"))
      assert(String.contains?(result, "<a href=\"#map-2\" class=\"anchor-link\">#</a>"))
    }

    test("public macro swaps the badge to macro") {
      result = Zap.Doc.function_header("twice", 1, true)
      assert(String.contains?(result, "<span class=\"badge\">macro</span>"))
    }

    test("header HTML-escapes the function name") {
      result = Zap.Doc.function_header("<bad>", 0, false)
      assert(String.contains?(result, "&lt;bad&gt;"))
    }
  }

  describe("Zap.Doc.implements_row") {
    test("empty protocol list renders nothing") {
      empty = empty_string_list()
      assert(Zap.Doc.implements_row(empty) == "")
    }

    test("renders one accent link per protocol") {
      result = Zap.Doc.implements_row(["Arithmetic", "Comparator"])
      assert(String.contains?(result, "<span class=\"implements-label\">Implements</span>"))
      assert(String.contains?(result, "../structs/Arithmetic.html"))
      assert(String.contains?(result, "../structs/Comparator.html"))
    }

    test("wraps the row in the implements div") {
      result = Zap.Doc.implements_row(["Stringable"])
      assert(String.starts_with?(result, "<div class=\"implements\">"))
      assert(String.ends_with?(result, "</div>\n"))
    }
  }
}
