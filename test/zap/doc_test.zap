pub struct Zap.DocTest {
  use Zest.Case

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

  describe("Zap.Doc.implements_row") {
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
