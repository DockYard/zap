@doc = """
  Render the subset of Markdown the Zap documentation generator emits
  into HTML strings. Supports paragraphs, ATX headings (`##`, `###`,
  `####`), and HTML escaping of body text.

  This is the working substrate for the doc generator's prose rendering.
  Block constructs (lists, fenced code, pipe tables) and inline runs
  (`**bold**`, `*italic*`, backtick code spans) will land as the doc
  generator that depends on them is ported piece by piece.
  """

pub struct Markdown {
  @doc = """
    Render `markdown` as HTML. Returns the empty string for empty input.
    """

  pub fn to_html(markdown :: String) -> String {
    if String.length(markdown) == 0 {
      ""
    } else {
      render_lines(String.split(markdown, "\n"), :start, "")
    }
  }

  @doc = """
    Walk the input line by line, tracking which block construct is
    currently open and emitting the right close/open tags as the line
    shape changes. `mode` is one of:

    - `:start`     — nothing emitted yet
    - `:paragraph` — last line opened a `<p>`
    """

  pub fn render_lines(lines :: [String], mode :: Atom, acc :: String) -> String {
    case lines {
      [] -> close_block(mode, acc)
      [line | rest] -> render_line(line, rest, mode, acc)
    }
  }

  @doc = """
    Classify a single line and emit its opening / closing tags into the
    accumulator. `mode` describes the in-flight block; `rest` is the
    remaining lines to render after this one.
    """

  pub fn render_line(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    if is_blank_line?(line) {
      render_lines(rest, :start, close_block(mode, acc))
    } else {
      if is_heading?(line, "#### ") {
        render_lines(rest, :start, close_block(mode, acc) <> render_heading("h4", String.slice(line, 5, String.length(line))))
      } else {
        if is_heading?(line, "### ") {
          render_lines(rest, :start, close_block(mode, acc) <> render_heading("h3", String.slice(line, 4, String.length(line))))
        } else {
          if is_heading?(line, "## ") {
            render_lines(rest, :start, close_block(mode, acc) <> render_heading("h2", String.slice(line, 3, String.length(line))))
          } else {
            render_paragraph_line(line, rest, mode, acc)
          }
        }
      }
    }
  }

  @doc = """
    Append a paragraph line. When `mode` is already `:paragraph` we
    emit a `\n` between this line and the previous one so multi-line
    paragraphs render as a single `<p>` block.
    """

  pub fn render_paragraph_line(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    if mode == :paragraph {
      render_lines(rest, :paragraph, acc <> "\n" <> escape_html(line))
    } else {
      render_lines(rest, :paragraph, acc <> "<p>" <> escape_html(line))
    }
  }

  pub fn close_block(mode :: Atom, acc :: String) -> String {
    if mode == :paragraph {
      acc <> "</p>\n"
    } else {
      acc
    }
  }

  pub fn render_heading(tag :: String, text :: String) -> String {
    "<" <> tag <> ">" <> escape_html(text) <> "</" <> tag <> ">\n"
  }

  pub fn is_blank_line?(line :: String) -> Bool {
    String.length(String.trim(line)) == 0
  }

  pub fn is_heading?(line :: String, prefix :: String) -> Bool {
    String.starts_with?(line, prefix)
  }

  @doc = """
    Escape the four characters that would otherwise be interpreted as
    HTML structure: `&`, `<`, `>`, and `"`. The renderer never emits
    raw single quotes, so no `&#39;` substitution.
    """

  pub fn escape_html(text :: String) -> String {
    escape_chars(text, 0, String.length(text), "")
  }

  pub fn escape_chars(text :: String, index :: i64, end :: i64, acc :: String) -> String {
    if index >= end {
      acc
    } else {
      ch = String.byte_at(text, index)
      escape_chars(text, index + 1, end, acc <> escape_one(ch))
    }
  }

  pub fn escape_one(ch :: String) -> String {
    if ch == "&" {
      "&amp;"
    } else {
      if ch == "<" {
        "&lt;"
      } else {
        if ch == ">" {
          "&gt;"
        } else {
          if ch == "\"" {
            "&quot;"
          } else {
            ch
          }
        }
      }
    }
  }
}
