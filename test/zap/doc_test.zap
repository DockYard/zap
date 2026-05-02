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
      _expected = "<nav class=\"breadcrumb\" aria-label=\"Breadcrumb\">\n<span>Structs</span>\n<span>/</span>\n<span class=\"breadcrumb-current\">Enum</span>\n</nav>\n"
      assert(Zap.Doc.breadcrumb(:struct, "Enum") == _expected)
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
      _result = Zap.Doc.summary_row("map", 2, "Transforms each element.")
      assert(String.contains?(_result, "<tr><td class=\"summary-name\"><a href=\"#map-2\">map/2</a></td>"))
      assert(String.contains?(_result, "<td class=\"summary-doc\">Transforms each element.</td>"))
    }

    test("HTML-escapes the summary text") {
      _result = Zap.Doc.summary_row("danger", 0, "use < not &")
      assert(String.contains?(_result, "use &lt; not &amp;"))
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
      _result = Zap.Doc.sidebar_group("Structs", ["Atom", "Bool", "Enum"], "Bool", "../")
      assert(String.contains?(_result, "data-group=\"Structs\""))
      assert(String.contains?(_result, "<button class=\"sidebar-group-header\""))
      assert(String.contains?(_result, "<h4>Structs</h4>"))
      assert(String.contains?(_result, "<li><a href=\"../structs/Atom.html\">Atom</a></li>"))
      assert(String.contains?(_result, "<li class=\"active\"><a href=\"../structs/Bool.html\">Bool</a></li>"))
      assert(String.contains?(_result, "<li><a href=\"../structs/Enum.html\">Enum</a></li>"))
    }

    test("empty current name leaves all items inactive") {
      _result = Zap.Doc.sidebar_group("Structs", ["Atom"], "", "../")
      assert(String.contains?(_result, "<li><a"))
      assert(String.contains?(_result, "class=\"active\"") == false)
    }
  }

  describe("Zap.Doc.summary_table") {
    test("empty rows body renders nothing") {
      assert(Zap.Doc.summary_table("Functions", "functions", "") == "")
    }

    test("non-empty rows wrap in heading and table") {
      _row = Zap.Doc.summary_row("map", 2, "Transforms each element.")
      _result = Zap.Doc.summary_table("Functions", "functions", _row)
      assert(String.starts_with?(_result, "<h2 id=\"functions\">Functions</h2>"))
      assert(String.contains?(_result, "<table class=\"summary\">"))
      assert(String.contains?(_result, "<a href=\"#map-2\">map/2</a>"))
      assert(String.ends_with?(_result, "</table>\n"))
    }
  }

  describe("Zap.Doc.module_main_content") {
    test("composes breadcrumb, title, implements, tagline, structdoc, sections in order") {
      _result = Zap.Doc.module_main_content(:struct, "Enum", ["Enumerable"], "A range of integers.", "<p>body</p>\n", "<tr><td>row</td></tr>\n", "", "<div class=\"function-detail\" id=\"map-2\">d</div>\n", "")
      assert(String.contains?(_result, "<span class=\"breadcrumb-current\">Enum</span>"))
      assert(String.contains?(_result, "<h1 class=\"page-title\">Enum</h1>"))
      assert(String.contains?(_result, "<a class=\"implements-link\" href=\"../structs/Enumerable.html\">"))
      assert(String.contains?(_result, "<p class=\"tagline\">A range of integers.</p>"))
      assert(String.contains?(_result, "<div class=\"structdoc\">\n<p>body</p>"))
      assert(String.contains?(_result, "<h2 id=\"functions\">Functions</h2>"))
      assert(String.contains?(_result, "<h2>Function Details</h2>"))
    }

    test("empty structdoc/macros/details collapse cleanly") {
      _result = Zap.Doc.module_main_content(:struct, "Empty", empty_string_list(), "", "", "", "", "", "")
      assert(String.contains?(_result, "<h1 class=\"page-title\">Empty</h1>"))
      assert(String.contains?(_result, "implements-link") == false)
      assert(String.contains?(_result, "structdoc") == false)
      assert(String.contains?(_result, "<h2") == false)
    }
  }

  describe("Zap.Doc.struct_page") {
    test("wraps chrome around composed sidebar / main / rail") {
      _result = Zap.Doc.struct_page("zap_stdlib", "0.1.0", "Enum", "../", "", "<nav class=\"sidebar\">S</nav>", "main", "<aside class=\"toc\">R</aside>")
      assert(String.starts_with?(_result, "<!DOCTYPE html>"))
      assert(String.contains?(_result, "<title>Enum"))
      assert(String.contains?(_result, "<header class=\"topbar\">"))
      assert(String.contains?(_result, "<nav class=\"sidebar\">S</nav>"))
      assert(String.contains?(_result, "<main class=\"content\">\nmain</main>"))
      assert(String.contains?(_result, "<aside class=\"toc\">R</aside>"))
      assert(String.contains?(_result, "<script src=\"../app.js\">"))
      assert(String.ends_with?(_result, "</body>\n</html>\n"))
    }
  }

  describe("Zap.Doc.layout") {
    test("with right rail uses the three-column layout") {
      _result = Zap.Doc.layout("<nav>S</nav>", "body", "<aside>R</aside>")
      assert(String.starts_with?(_result, "<div class=\"layout\">"))
      assert(String.contains?(_result, "<nav>S</nav>"))
      assert(String.contains?(_result, "<main class=\"content\">\nbody</main>"))
      assert(String.contains?(_result, "<aside>R</aside>"))
    }

    test("without right rail uses the two-column layout") {
      _result = Zap.Doc.layout("<nav>S</nav>", "body", "")
      assert(String.starts_with?(_result, "<div class=\"layout layout-no-toc\">"))
      assert(String.contains?(_result, "<aside") == false)
    }
  }

  describe("Zap.Doc.sidebar") {
    test("renders one group per non-empty member list") {
      _result = Zap.Doc.sidebar(["Atom", "Bool"], ["Stringable"], empty_string_list(), "Bool", "../")
      assert(String.starts_with?(_result, "<nav class=\"sidebar\">"))
      assert(String.contains?(_result, "<h4>Structs</h4>"))
      assert(String.contains?(_result, "<h4>Protocols</h4>"))
      assert(String.contains?(_result, "<h4>Unions</h4>") == false)
      assert(String.contains?(_result, "<li class=\"active\"><a href=\"../structs/Bool.html\">Bool</a></li>"))
    }

    test("empty groups produce a sidebar with only the search header") {
      _empty = empty_string_list()
      _result = Zap.Doc.sidebar(_empty, _empty, _empty, "", "")
      assert(String.contains?(_result, "<h4>") == false)
      assert(String.contains?(_result, "<div class=\"sidebar-search\">"))
    }
  }

  describe("Zap.Doc.topbar") {
    test("renders brand, search trigger, theme toggle, github link") {
      _result = Zap.Doc.topbar("zap_stdlib", "0.1.0", "../", "https://github.com/DockYard/zap")
      assert(String.starts_with?(_result, "<header class=\"topbar\">"))
      assert(String.contains?(_result, "<a href=\"../index.html\" class=\"topbar-title\">zap_stdlib</a>"))
      assert(String.contains?(_result, "<span class=\"topbar-version\">v0.1.0</span>"))
      assert(String.contains?(_result, "id=\"search-trigger\""))
      assert(String.contains?(_result, "id=\"theme-toggle\""))
      assert(String.contains?(_result, "href=\"https://github.com/DockYard/zap\""))
    }

    test("empty source_url omits the github link") {
      _result = Zap.Doc.topbar("name", "0.0.0", "", "")
      assert(String.contains?(_result, "topbar-github") == false)
    }
  }

  describe("Zap.Doc.page_open") {
    test("renders doctype, head, and body open") {
      _result = Zap.Doc.page_open("Enum", "zap_stdlib", "../")
      assert(String.starts_with?(_result, "<!DOCTYPE html>"))
      assert(String.contains?(_result, "<title>Enum"))
      assert(String.contains?(_result, "<link rel=\"stylesheet\" href=\"../style.css\">"))
      assert(String.contains?(_result, "<meta name=\"zap-docs-base\" content=\"../\">"))
      assert(String.ends_with?(_result, "</head>\n<body>\n"))
    }
  }

  describe("Zap.Doc.page_close") {
    test("renders search modal and closing script") {
      _result = Zap.Doc.page_close("../")
      assert(String.contains?(_result, "id=\"search-modal\""))
      assert(String.contains?(_result, "<script src=\"../app.js\">"))
      assert(String.ends_with?(_result, "</body>\n</html>\n"))
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
      _items = Zap.Doc.toc_item("map", 2)
      _result = Zap.Doc.right_rail(_items)
      assert(String.starts_with?(_result, "<aside class=\"toc\">"))
      assert(String.contains?(_result, "<h3>On This Page</h3>"))
      assert(String.contains?(_result, "<li><a href=\"#map-2\">map/2</a></li>"))
      assert(String.ends_with?(_result, "</aside>\n"))
    }
  }

  describe("Zap.Doc.function_details_section") {
    test("empty body renders nothing") {
      assert(Zap.Doc.function_details_section("Function Details", "") == "")
    }

    test("non-empty body wraps in heading") {
      _block = Zap.Doc.function_detail("map", 2, false, ["map(x :: i64) -> i64"], "<p>Transforms.</p>\n")
      _result = Zap.Doc.function_details_section("Function Details", _block)
      assert(String.starts_with?(_result, "<h2>Function Details</h2>"))
      assert(String.contains?(_result, "<div class=\"function-detail\" id=\"map-2\">"))
    }
  }

  describe("Zap.Doc.function_detail") {
    test("composes id, header, signature, and rendered doc") {
      _result = Zap.Doc.function_detail("map", 2, false, ["map(value :: i64) -> i64"], "<p>Transforms each element.</p>\n")
      assert(String.starts_with?(_result, "<div class=\"function-detail\" id=\"map-2\">"))
      assert(String.contains?(_result, "<span class=\"badge\">fn</span>"))
      assert(String.contains?(_result, "<div class=\"signature\">"))
      assert(String.contains?(_result, "<div class=\"function-doc\">\n<p>Transforms each element.</p>\n</div>"))
      assert(String.ends_with?(_result, "</div>\n"))
    }

    test("multi-clause functions get multiple signature panels") {
      _result = Zap.Doc.function_detail("classify", 1, false, ["classify(0 :: i64) -> String", "classify(value :: i64) -> String"], "")
      assert(String.contains?(_result, "0 :: i64"))
      assert(String.contains?(_result, "value :: i64"))
    }

    test("undocumented functions omit the doc div") {
      _result = Zap.Doc.function_detail("noop", 0, false, ["noop() -> Atom"], "")
      assert(String.contains?(_result, "function-doc") == false)
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
      _result = Zap.Doc.function_header("map", 2, false)
      assert(String.contains?(_result, "<h3>map<span class=\"arity\">/2</span></h3>"))
      assert(String.contains?(_result, "<span class=\"badge\">fn</span>"))
      assert(String.contains?(_result, "<a href=\"#map-2\" class=\"anchor-link\">#</a>"))
    }

    test("public macro swaps the badge to macro") {
      _result = Zap.Doc.function_header("twice", 1, true)
      assert(String.contains?(_result, "<span class=\"badge\">macro</span>"))
    }

    test("header HTML-escapes the function name") {
      _result = Zap.Doc.function_header("<bad>", 0, false)
      assert(String.contains?(_result, "&lt;bad&gt;"))
    }
  }

  describe("Zap.Doc.implements_row") {
    test("empty protocol list renders nothing") {
      _empty = empty_string_list()
      assert(Zap.Doc.implements_row(_empty) == "")
    }

    test("renders one accent link per protocol") {
      _result = Zap.Doc.implements_row(["Arithmetic", "Comparator"])
      assert(String.contains?(_result, "<span class=\"implements-label\">Implements</span>"))
      assert(String.contains?(_result, "../structs/Arithmetic.html"))
      assert(String.contains?(_result, "../structs/Comparator.html"))
    }

    test("wraps the row in the implements div") {
      _result = Zap.Doc.implements_row(["Stringable"])
      assert(String.starts_with?(_result, "<div class=\"implements\">"))
      assert(String.ends_with?(_result, "</div>\n"))
    }
  }
}
