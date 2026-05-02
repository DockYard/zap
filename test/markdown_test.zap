pub struct MarkdownTest {
  use Zest.Case

  describe("empty and whitespace inputs") {
    test("empty string renders as empty string") {
      assert(Markdown.to_html("") == "")
    }
  }

  describe("paragraphs") {
    test("a single line becomes a paragraph") {
      assert(Markdown.to_html("hello") == "<p>hello</p>\n")
    }

    test("two paragraphs are separated by a blank line") {
      assert(Markdown.to_html("first\n\nsecond") == "<p>first</p>\n<p>second</p>\n")
    }

    test("consecutive lines join into one paragraph") {
      assert(Markdown.to_html("line one\nline two") == "<p>line one\nline two</p>\n")
    }
  }

  describe("headings") {
    test("## becomes h2") {
      assert(Markdown.to_html("## Title") == "<h2>Title</h2>\n")
    }

    test("### becomes h3") {
      assert(Markdown.to_html("### Subtitle") == "<h3>Subtitle</h3>\n")
    }

    test("#### becomes h4") {
      assert(Markdown.to_html("#### Sub-subtitle") == "<h4>Sub-subtitle</h4>\n")
    }

    test("a heading followed by a paragraph closes cleanly") {
      assert(Markdown.to_html("## Title\nbody") == "<h2>Title</h2>\n<p>body</p>\n")
    }
  }

  describe("HTML escaping") {
    test("less-than is escaped in body text") {
      assert(Markdown.to_html("a < b") == "<p>a &lt; b</p>\n")
    }

    test("ampersand is escaped in body text") {
      assert(Markdown.to_html("Tom & Jerry") == "<p>Tom &amp; Jerry</p>\n")
    }
  }
}
