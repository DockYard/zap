@doc = """
  Render the subset of Markdown the Zap documentation generator emits
  into HTML strings. Supports paragraphs, ATX headings (`##`, `###`,
  `####`), unordered lists (`- item` or `* item`), fenced code blocks
  with optional language tags, inline `code spans`, and HTML escaping
  of body text.

  The renderer is a small block-then-inline state machine. Block parsing
  walks the input line by line, tracking which block construct is open
  (`:start`, `:paragraph`, `:list`, `:code`) and emitting close/open
  tags as the line shape changes. Inline rendering escapes HTML special
  characters and recognizes backtick-delimited code spans.
  """

pub struct Markdown {
  @doc = """
    Render `markdown` as HTML. Returns the empty string for empty input.
    """

  pub fn to_html(markdown :: String) -> String {
    if String.length(markdown) == 0 {
      ""
    } else {
      render_lines(String.split(markdown, "\n"), :start, "", "")
    }
  }

  @doc = """
    Walk the input line by line, tracking which block construct is
    currently open and emitting the right close/open tags as the line
    shape changes. `mode` is one of `:start`, `:paragraph`, `:list`,
    or `:code`. `code_lang` carries the language tag for an open code
    block; it's the empty string in any other mode.
    """

  pub fn render_lines(lines :: [String], mode :: Atom, code_lang :: String, acc :: String) -> String {
    case lines {
      [] -> close_block(mode, acc)
      [line | rest] -> render_line(line, rest, mode, code_lang, acc)
    }
  }

  pub fn render_line(line :: String, rest :: [String], mode :: Atom, code_lang :: String, acc :: String) -> String {
    if mode == :code {
      if String.starts_with?(String.trim(line), "```") {
        render_lines(rest, :start, "", acc <> "</code></pre>\n")
      } else {
        render_lines(rest, :code, code_lang, acc <> escape_html(line))
      }
    } else {
      classify_line(line, rest, mode, acc)
    }
  }

  @doc = """
    Recognize the line's block kind for non-code modes and dispatch.
    Order matters: code-fence opens before headings, headings before
    list items, list items before paragraphs.
    """

  pub fn classify_line(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    if is_blank_line?(line) {
      render_lines(rest, :start, "", close_block(mode, acc))
    } else {
      if String.starts_with?(String.trim(line), "```") {
        open_code_block(line, rest, mode, acc)
      } else {
        if String.starts_with?(line, "#### ") {
          render_lines(rest, :start, "", close_block(mode, acc) <> render_heading("h4", String.slice(line, 5, String.length(line))))
        } else {
          if String.starts_with?(line, "### ") {
            render_lines(rest, :start, "", close_block(mode, acc) <> render_heading("h3", String.slice(line, 4, String.length(line))))
          } else {
            if String.starts_with?(line, "## ") {
              render_lines(rest, :start, "", close_block(mode, acc) <> render_heading("h2", String.slice(line, 3, String.length(line))))
            } else {
              if is_list_item?(line) {
                render_list_item(line, rest, mode, acc)
              } else {
                render_paragraph_line(line, rest, mode, acc)
              }
            }
          }
        }
      }
    }
  }

  pub fn open_code_block(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    trimmed = String.trim(line)
    lang = String.slice(trimmed, 3, String.length(trimmed))
    closed = close_block(mode, acc)
    if String.length(lang) == 0 {
      render_lines(rest, :code, "", closed <> "<pre><code>")
    } else {
      render_lines(rest, :code, lang, closed <> "<pre><code class=\"language-" <> lang <> "\">")
    }
  }

  pub fn render_list_item(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    text = list_item_text(line)
    if mode == :list {
      render_lines(rest, :list, "", acc <> "</li>\n<li>" <> render_inline(text))
    } else {
      render_lines(rest, :list, "", close_block(mode, acc) <> "<ul>\n<li>" <> render_inline(text))
    }
  }

  pub fn render_paragraph_line(line :: String, rest :: [String], mode :: Atom, acc :: String) -> String {
    if mode == :paragraph {
      render_lines(rest, :paragraph, "", acc <> "\n" <> render_inline(line))
    } else {
      render_lines(rest, :paragraph, "", close_block(mode, acc) <> "<p>" <> render_inline(line))
    }
  }

  pub fn close_block(mode :: Atom, acc :: String) -> String {
    if mode == :paragraph {
      acc <> "</p>\n"
    } else {
      if mode == :list {
        acc <> "</li>\n</ul>\n"
      } else {
        acc
      }
    }
  }

  pub fn render_heading(tag :: String, text :: String) -> String {
    "<" <> tag <> ">" <> render_inline(text) <> "</" <> tag <> ">\n"
  }

  pub fn is_blank_line?(line :: String) -> Bool {
    String.length(String.trim(line)) == 0
  }

  pub fn is_list_item?(line :: String) -> Bool {
    String.starts_with?(line, "- ") or String.starts_with?(line, "* ")
  }

  pub fn list_item_text(line :: String) -> String {
    String.slice(line, 2, String.length(line))
  }

  @doc = """
    Render a single inline run: HTML-escape body text, but recognize
    backtick-delimited code spans and wrap them as `<code>`. Backticks
    nest one level — content between matching pairs is escaped but
    not further parsed for inline syntax.
    """

  pub fn render_inline(text :: String) -> String {
    inline_walk(text, 0, String.length(text), false, "")
  }

  pub fn inline_walk(text :: String, index :: i64, end :: i64, in_code :: Bool, acc :: String) -> String {
    if index >= end {
      acc
    } else {
      ch = String.byte_at(text, index)
      if ch == "`" {
        if in_code {
          inline_walk(text, index + 1, end, false, acc <> "</code>")
        } else {
          inline_walk(text, index + 1, end, true, acc <> "<code>")
        }
      } else {
        inline_walk(text, index + 1, end, in_code, acc <> escape_one(ch))
      }
    }
  }

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
