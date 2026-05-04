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

  describe("unordered lists") {
    test("a single dash item becomes a one-element ul") {
      assert(Markdown.to_html("- alpha") == "<ul>\n<li>alpha</li>\n</ul>\n")
    }

    test("contiguous list items collapse into one ul") {
      assert(Markdown.to_html("- alpha\n- beta") == "<ul>\n<li>alpha</li>\n<li>beta</li>\n</ul>\n")
    }

    test("a list followed by a paragraph closes cleanly") {
      assert(Markdown.to_html("- alpha\n\ntext") == "<ul>\n<li>alpha</li>\n</ul>\n<p>text</p>\n")
    }

    test("an asterisk also opens a list item") {
      assert(Markdown.to_html("* alpha") == "<ul>\n<li>alpha</li>\n</ul>\n")
    }
  }

  describe("inline code spans") {
    test("backticks in a paragraph wrap as <code>") {
      assert(Markdown.to_html("use `Enum.map` to transform") == "<p>use <code>Enum.map</code> to transform</p>\n")
    }

    test("two adjacent code spans both render") {
      assert(Markdown.to_html("`a` and `b`") == "<p><code>a</code> and <code>b</code></p>\n")
    }

    test("HTML inside backticks is still escaped") {
      assert(Markdown.to_html("`a < b`") == "<p><code>a &lt; b</code></p>\n")
    }
  }

  describe("fenced code blocks") {
    test("a triple-backtick block becomes <pre><code>") {
      assert(Markdown.to_html("```\nhello\n```") == "<pre><code>hello</code></pre>\n")
    }

    test("a language tag becomes a class") {
      assert(Markdown.to_html("```sh\necho hi\n```") == "<pre><code class=\"language-sh\">echo hi</code></pre>\n")
    }

    test("HTML special characters in the body are escaped") {
      assert(Markdown.to_html("```\na < b\n```") == "<pre><code>a &lt; b</code></pre>\n")
    }

    test("a multi-line body preserves line breaks") {
      assert(Markdown.to_html("```\nline one\nline two\n```") == "<pre><code>line one\nline two</code></pre>\n")
    }
  }

  describe("pipe tables") {
    test("a header / separator / row trio renders a markdown-table") {
      input = "| Field | Description |\n| --- | --- |\n| name | Output name |"
      expected = "<table class=\"markdown-table\">\n<thead>\n<tr><th>Field</th><th>Description</th></tr>\n</thead>\n<tbody>\n<tr><td>name</td><td>Output name</td></tr>\n</tbody>\n</table>\n"
      assert(Markdown.to_html(input) == expected)
    }
  }
}
